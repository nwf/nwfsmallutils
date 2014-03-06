/*
 * (C) 2014 Nathaniel Wesley Filardo <nwf@cs.jhu.edu>
 *
 * Rabin Fingerprint stream/file splitter
 *
 * This is intended as a pre-processing stage to content-addressed storage
 * systems (e.g. Venti).  Either take a large file and split it, or make a
 * tarball and split that, then vac up the resulting files.  The idea is that
 * we find stable parts of the files between signatures, so even if the
 * offsets change, we'll recover.
 *
 * For technical discussion, see
 * http://gsoc.cat-v.org/people/mjl/blog/2007/08/06/1_Rabin_fingerprints/
 * and
 * Center for Research in Computing Technology, Harvard University. Tech
 * Report TR-CSE-03-01.  http://www.xmailserver.org/rabin.pdf
 *
 * Build with
 *  gcc -Wall --std=gnu99 -o rabinsplit rabinsplit.c
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <errno.h>
#include <getopt.h>

const unsigned int mulprime = 7;
const unsigned int win_data_offset = 1;

struct {
  unsigned int debug;
  unsigned int writing;
  unsigned int winsize;
  unsigned int modulus;
  unsigned int minsize;
  char *outpfx;
  unsigned int shiftout[256];
} params;

struct {
  unsigned int *wind_head;
  unsigned int *wind_end;
  unsigned int *wind_cur;
  unsigned int wind_sum;
  unsigned long chunksize;
  unsigned long totalsize;
  unsigned int chunkcount;
  FILE *outfile;
} ss;

void build_shiftout(unsigned int so[256]) {
  for (int i = 0; i < 256; i++) {
    so[i] = i + win_data_offset;
  }
  for (int x = 0; x < params.winsize; x++) {
    for (int i = 0; i < 256; i++) {
      so[i] = (so[i] * mulprime) % params.modulus;
    }
  }
}

void dosplit(void) {
  if (params.debug) {
    printf("SPLIT chunk=%u chunkbytes=%lu totalbytes=%lu\n",
            ss.chunkcount, ss.chunksize, ss.totalsize);
  }

  ss.chunksize = 0;
  if(ss.outfile) {
    fclose(ss.outfile);
  }
  if(params.writing) {
    char buf[128];
    int n = snprintf(buf, sizeof(buf), "%s%08d", params.outpfx, ss.chunkcount);
    if (n >= sizeof(buf)) {
      fprintf(stderr, "Overlong output filename; bailing out.");
      exit(-1);
    }
    
    ss.outfile = fopen(buf, "w+b");
    if(!ss.outfile) {
      fprintf(stderr, "Unable to open file: %s (errno=%d)", buf, errno);
      exit(-1);
    }
  }
  ss.chunkcount++;  
}

void procbyte(uint8_t in) {
    ss.chunksize++;
    ss.totalsize++;

    ss.wind_sum *= mulprime;
    ss.wind_sum += in + win_data_offset;
	ss.wind_sum -= *ss.wind_cur;
    ss.wind_sum %= params.modulus;

	*ss.wind_cur = params.shiftout[in];

    if(++ss.wind_cur == ss.wind_end) { ss.wind_cur = ss.wind_head; }
    if(ss.outfile) { fputc(in,ss.outfile); }
    if((ss.wind_sum == params.modulus - 1)
        && ss.chunksize >= params.minsize) { dosplit(); }
}

long
safe_strtoul(char *p, char *err) {
  char *endp;
  unsigned long int r;

  errno = 0;
  r = strtoul(p, &endp, 10);
  if ((*endp != '\0') || (errno != 0)) {
    fprintf(stderr, "Could not understand %s %s (tail=%s, errno=%d)\n", err, p, endp, errno); 
    exit(-1);
  }

  return r;
}

void
help(void) {
  printf("Rabin split options:\n");
  printf("\t-m <minimum chunk size>\n");
  printf("\t-n disable writing\n");
  printf("\t-o <output filename prefix>\n");
  printf("\t-v enables verbose debugging output\n");
  printf("\t-w <window size>\n");
  printf("\t-z <window modulus>\n");
  exit(0);
}

int
main(int argc, char **argv) {
  params.debug   = 0;
  params.writing = 1;
  params.winsize = 31;
  params.minsize = 4096;
  params.modulus = 10*1024*1024;

  {
    int opt;
    while((opt = getopt(argc, argv, "hm:no:vw:z:")) != -1) {
      switch(opt) {
      case 'h': help(); break;
      case 'm': params.minsize = safe_strtoul(optarg, "minsize"); break;
      case 'n': params.writing = 0; break;
      case 'o': params.outpfx = optarg; break;
      case 'v': params.debug++; break;
      case 'w': params.winsize = safe_strtoul(optarg, "window size"); break;
      case 'z': params.modulus = safe_strtoul(optarg, "modulus"); break;
      default: fprintf(stderr, "Unrecognized option: '%c'\n", opt); help(); break;
      }
    }
  }

  {
    int bsize = params.winsize * sizeof(*ss.wind_head);
    ss.wind_head = alloca(bsize);
    ss.wind_end  = ss.wind_head + params.winsize;
    ss.wind_cur  = ss.wind_head;
    ss.wind_sum  = 0;
    for (int i = 0; i < params.winsize; i++)
    {
	  ss.wind_head[i] = 0;
    }
	ss.chunkcount = 0;
	ss.chunksize = 0;
	ss.totalsize = 0;
	ss.outfile = NULL;
  }

  build_shiftout(params.shiftout);
  dosplit(); // Get the party started

  int ci;
  while((ci = fgetc(stdin)) >= 0) {
    procbyte((uint8_t) ci);
  }
}
