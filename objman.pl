#!/usr/bin/perl -w

my $C_INDEXDB = "__objmandb";
my $O_VERBOSE;

use strict;
use warnings;
use BerkeleyDB;
use Cwd 'abs_path';
use Data::Dumper;
require Digest;
require Digest::SHA;
use File::Basename;
use File::Compare;
use File::Copy;
use File::Next;
use Getopt::Long;
use IO::Handle;
use IO::File;
use POSIX;

# For testing hash collisions, use this.
#my $G_DIGEST = 'CRC';
#my $G_DIGESTER = Digest->new($G_DIGEST, type=>"crc8");

# For day-to-day operations. use a real hash function, like SHA1:
my $G_DIGEST = 'SHA1';
my $G_DIGESTER = Digest->new($G_DIGEST);

sub hashfile ($) {
  my $fh = IO::File->new(@_);

  $G_DIGESTER->addfile($fh);
  return $G_DIGESTER->hexdigest;

  # Note that reading ->hexdigest triggers a reset of the object,
  # so we're perfectly OK having just one.
}

sub del_cursor_and_file($$$) {
  my ($db_fh, $cursor, $file) = @_;
  $cursor->c_del();
  $db_fh->db_del($file);
}

sub open_db ($$$) {
  my ($dbfile, $subname, $dupes) = @_;

  $dbfile = $dbfile . "-" . $subname;

  my $db = new BerkeleyDB::Btree
# XXX Why don't sub databases work?!
# Can I really not have two concurrent operations through this API?
              -Filename => $dbfile,
#							-Subname => $subname,
              -Flags		=> DB_CREATE ,
              -Property	=> ($dupes ? DB_DUP : 0)
  or die "Cannot open file $dbfile: '$!' '$BerkeleyDB::Error'\n" ;

  return $db;
}

sub build_index ($$$$) {
  my ($db_hf, $db_fh, $collection, $newonly) = @_;

  my $ignored = "";
  my $fileiter = File::Next::files ( $collection );

  while ( defined ( my $file = $fileiter->() ) ) {
    # XXX HACK to prevent the index from trying to contain itself
    next if $file =~ /$collection\/$C_INDEXDB.*/;
    next if $newonly and $db_fh->db_get($file, $ignored) == 0;

    my $hash = hashfile($file);
    print STDERR "  Digest of $file is $hash\n" if $O_VERBOSE;
    print STDERR "  Added $file\n" if $newonly and not $O_VERBOSE;
    $db_hf->db_put($hash, $file);
    $db_fh->db_put($file, $hash);
  }
}

sub printdb ($) {
  my ($db) = @_;

  my $cursor = $db->db_cursor();
  my ($k, $v) = ("","");

  while ($cursor->c_get ($k, $v, DB_NEXT) == 0)
  {
    print " $k:\n";
    do {
      print "  $v\n";
    } while ( $cursor->c_get ($k, $v, DB_NEXT_DUP) == 0 );
  }
}


sub filecheck ($$$) {
  my ($db_hf, $db_fh, $collection) = @_;

  my $cursor = $db_fh->db_cursor();
  my ($k, $v) = ("","");

  print STDERR "Checking over files...\n";

  while ($cursor->c_get ($k, $v, DB_NEXT) == 0)
  {
    my $count;
    $cursor->c_count($count);

    print STDERR " Checking $k:\n" if $O_VERBOSE;

    if (not -e $k)
    {
      print STDERR "   $k seems to have gone away by itself...\n";
      $cursor->c_del();
      next;
    }

    if (not -r $k)
    {
      print STDERR "   No longer allowed to read $k?\n".
      $cursor->c_del();
      next;
    }

    my $newhash = hashfile($k);

    if ($newhash ne $v)
    {
      print STDERR "   File $k changed from $v to $newhash"
                   . "; pointwise semi-updating database.\n";
      # XXX
      # Can't delete the specific entry in the hash->file map.
      # So we'll just let the deletion detector take care of it.
      $cursor->c_del();
      $db_hf->db_put($newhash, $k);
      $db_fh->db_put($k, $newhash);
      next;
    }
  }

  print STDERR "Done checking.\n";
}

sub dupecheck ($$$$) {
  my ($db_hf, $db_fh, $collection, $prune) = @_;

  my $cursor = $db_hf->db_cursor();
  my ($k, $v) = ("","");

  print STDERR "Searching for duplicates...\n";

  while ($cursor->c_get ($k, $v, DB_NEXT) == 0)
  {
    my $count;
    $cursor->c_count($count);

    my $firstfile = $v;

    if ($count > 1)
    {
      if ($O_VERBOSE)
      {
        print STDERR " Database thinks duplicate files at $k:\n";
      } else {
        print STDERR " Database thinks these files are duplicates:\n";
      }

      my $index = 0;

      do {{
        print STDERR "  $v\n";

        if ($index != 0 and $firstfile eq $v)
        {
          print STDERR "   WARNING: DATABASE CORRUPTED ".
                       "(duplicate entry in hash)\n";
          $cursor->c_del();
        }

        if (not -e $v)
        {
          print STDERR "   File seems to have gone away by itself...\n";
          del_cursor_and_file($db_fh, $cursor, $v);
          next;
        }

        if (not -r $v)
        {
          print STDERR "   No longer allowed to read file?\n".
          del_cursor_and_file($db_fh, $cursor, $v);
          next;
        }

        my $newhash = hashfile($v);

        if ($newhash ne $k)
        {
          print STDERR "   File hash changed from $k to $newhash"
                       . "; pointwise updating database.\n";
          del_cursor_and_file($db_fh, $cursor, $v);
          $db_hf->db_put($newhash, $v);
          $db_fh->db_put($v, $newhash);
      
          print STDERR "Restarting...\n";
          print STDERR "=" x 76 . "\n";

          # Create a new cursor and start over.
          $cursor = $db_hf->db_cursor();
          ($k, $v) = ("","");
          last;
        }

        ### Avoid comparing the first file to itself.
        if ($firstfile ne $v and (compare($v, $firstfile) == 0))
        {
          print STDERR "   Seems genuine...\n" if $O_VERBOSE;
          
          if ($prune)
          {
            print STDERR "   Removing file: $v\n";
            del_cursor_and_file($db_fh, $cursor, $v);
            unlink $v;
            last;
          }
        } elsif ( $firstfile ne $v ) {
          print STDERR "   Perhaps you should buy lottery tickets.\n";
        }

        # TODO A pairwise compare would be better

        $index++;
      }} while ( $cursor->c_get ($k, $v, DB_NEXT_DUP) == 0 );
    }	
  }

  print STDERR "Done searching for duplicates.\n";
}

  # Merge core
  # Return values:
  #	 0 - no merge necessary (duplicates detected)
  #	 1 - file merged successfully
  #	 -1 - unable to merge file
  #	 -2 - want to merge, but told not to
  #		-3 - please search for new files and re-attempt this merge
  #				 (mergefile found deletions or alterations while searching and
  #					did not find a copy of the original file; therefore, it is
  #					unsure of whether the file should be merged)
sub mergefile ($$$$$) {
  my ($db_hf, $db_fh, $destination, $newfile, $noact) = @_;

  my $hash = hashfile($newfile);
  my $findnew = 0;

  print STDERR " Hash is $hash\n" if $O_VERBOSE;

  my $cursor = $db_hf->db_cursor();
  my $oldfile;
  if ($cursor->c_get ($hash, $oldfile, DB_SET) == 0)
  {
    do {{ # Note the doubled braces so that "next" works.	See perlsyn.
      print STDERR "  Database suggests $oldfile ...\n" if $O_VERBOSE;

      if (not -r $oldfile)
      {
        print STDERR "   Detected a deletion...\n";
        del_cursor_and_file($db_fh, $cursor, $oldfile);

        $findnew = 1;
        next;
      }

      if (compare($oldfile, $newfile) == 0)
      {
        print STDERR "   And good thing too!	No merge necessary.\n"
          if $O_VERBOSE;
        return 0;
      }

      my $newhash = hashfile($oldfile);
      if ($newhash ne $hash)
      {
        print STDERR "   Hash mismatch; pointwise update...\n";
        del_cursor_and_file($db_fh, $cursor, $oldfile);
        $db_hf->db_put($newhash, $oldfile);
        $db_fh->db_put($oldfile, $newhash);

        $findnew = 1;
      }

    }} while ($cursor->c_get ($hash, $oldfile, DB_NEXT_DUP) == 0);
  }

  return -3 if $findnew == 1;

  my $destfile = $destination."/".basename($newfile);

  print STDERR "  MERGE $newfile INTO $destfile \n" if $O_VERBOSE;

  if (not $noact) {
    if(not sysopen DESTINATION, $destfile, O_RDWR|O_CREAT|O_EXCL )
    {
      print STDERR "   Bad juju while opening destination file: $!\n";
      return -1;
    }

    $db_hf->db_put($hash, $destfile);
    $db_fh->db_put($destfile, $hash);
    copy($newfile, *DESTINATION);

    close DESTINATION;
    return 1;
  } else {
    # Simulate a failure on no-action so that we don't delete files.
    return -2;
  }
}

my $O_COLLECTION;
my $O_DUPECHECK;
my $O_FILECHECK;
my $O_HELP;
my $O_LIST;
my $O_MERGE;
my $O_NEWDIRNAME;
my $O_NEWONLY;
my $O_NOMERGE;
my $O_PRUNE;
my $O_REBUILDINDEX;
my $O_SOURCEDIR;

my %cmdopts=(
  "c:s"       => \$O_COLLECTION,
  "d"         => \$O_DUPECHECK,
  "f"         => \$O_FILECHECK,
  "h|help"    => \$O_HELP,
  "l"         => \$O_LIST,
  "m"         => \$O_MERGE,
  "n:s"       => \$O_NEWDIRNAME,
  "o"         => \$O_NOMERGE,
  "prune"     => \$O_PRUNE,
  "r"         => \$O_REBUILDINDEX,
  "s:s"       => \$O_SOURCEDIR,
  "v"         => \$O_VERBOSE,
  "w"          => \$O_NEWONLY,
);
GetOptions(%cmdopts);

$O_HELP = 1 if not ($O_LIST or $O_MERGE or $O_DUPECHECK or $O_FILECHECK or $O_REBUILDINDEX);

if($O_HELP)
{
  print "Dump index:      $0 -l [-c Collection]\n";
  print "Rebuild index:   $0 -r [-w] [-c Collection]\n";
  print "Duplicate check: $0 -d [-c Collection]\n";
  print "File check:      $0 -f [-c Collection]\n";
  print "Merge usage:     $0 -m [-o] [-c Collection] [-n New] [-s Src]\n";
  print "Simulating merges:\n";
  print "  -o will cause -m to check what would be merged, but not merge files.\n";
  print "Deleting files:\n";
  print "  --prune will cause -d to delete duplicates from the collection.\n";
  print "  --prune will cause -m to delete duplicates from the source.\n";
  print "          Combined with -o, this will delete only already copied files.\n";
  print "          Combined with -w, this will delete only newly merged files.\n";
  print "          Combined with both -o and -w, this will have no effect.\n";
  print "Other options:\n";
  print "  -r optionally takes -w to search only for new files.\n";
  print "  If -v is given, I will verbosely explain my actions.\n";
  print "  If -h is given, I will display this help message.\n";
  print "Note that -lrdm are not exclusive, but mixes may be funny.\n";
  print "  The order of operations is -r, -d, -m, then -l.\n";
  exit 0;
}

if(not defined $O_COLLECTION)
{
  warn "Undefined collection: Assuming current directory." ;
  $O_COLLECTION=abs_path(".");
} else {
  $O_COLLECTION=abs_path($O_COLLECTION);
}

print STDERR "Working with collection '$O_COLLECTION'\n";

#die "Refusing to work on non-extant collection" unless -d $O_COLLECTION;
#die "Refusing to work on non-readable collection" unless -r $O_COLLECTION;
#die "Refusing to work on non-writable collection" unless -w $O_COLLECTION;
#die "Refusing to work on non-enterable collection" unless -x $O_COLLECTION;

my $indexfile = $O_COLLECTION . "/" . $C_INDEXDB;

# Force rebuild if index file doesn't exist
# TODO: Depends on proper access mechanisms to multiple sub databases at
# once...
#$O_REBUILDINDEX=1 if not -r $indexfile;

print STDERR " Index file is '$indexfile'\n" if $O_VERBOSE;
print STDERR " Berkely DB version is $BerkeleyDB::db_version\n" if $O_VERBOSE;

# Open the database
my $db_hf = open_db($indexfile, "hf", 1);		# Hash -> file name, dupes on
my $db_fh = open_db($indexfile, "fh", 0);		# File -> hash, dupes off

# If we are supposed to build the index, go do that now
if($O_REBUILDINDEX)
{
  print STDERR "Building index...\n";

  my ($oldh, $oldf) = (0,0);
  if (not $O_NEWONLY)
  {
    $db_hf->truncate($oldh);
    $db_fh->truncate($oldf);
  } else {
    $oldh = ${$db_hf->db_stat()}{'bt_ndata'};
    $oldf = ${$db_fh->db_stat()}{'bt_ndata'};
  }
  build_index ($db_hf, $db_fh, $O_COLLECTION, $O_NEWONLY);

  my $dbstat_hf = $db_hf->db_stat();
  my $dbstat_fh = $db_fh->db_stat();

  if ($O_VERBOSE)
  {
    print STDERR "Old database had $oldh hashes and $oldf files.\n";
    print STDERR "Now have ";
    print STDERR $$dbstat_hf {'bt_ndata'};
    print STDERR " hashes and ";
    print STDERR $$dbstat_fh {'bt_ndata'};
    print STDERR " files\n";
  }
}

if($O_DUPECHECK)
{
  dupecheck ($db_hf, $db_fh, $O_COLLECTION, $O_PRUNE);
}

if($O_FILECHECK)
{
  filecheck ($db_hf, $db_fh, $O_COLLECTION);
}

MERGE: {
  if($O_MERGE)
  {
    warn "Must specify a new directory for merge" and last MERGE
      unless $O_NEWDIRNAME or $O_NOMERGE;
    warn "Must specify a source directory for merge" and last MERGE
      unless $O_SOURCEDIR;

    my $newdir = abs_path($O_COLLECTION."/".$O_NEWDIRNAME);

    warn "Must specify a _new_ directory for merge!" and last MERGE
      if -d $newdir and not $O_NOMERGE;

    mkdir $newdir if not $O_NOMERGE;

    my $fileiter = File::Next::files ( $O_SOURCEDIR );

    while ( defined ( my $file = $fileiter->() ) )
    {
      MERGECORE: {
        print STDERR "Merging $file ...\n";

        my $retval = mergefile($db_hf, $db_fh, $newdir, $file, $O_NOMERGE);

        if ( $O_PRUNE and $retval == 1) {
          # Not keeping file and successfully merged
          print STDERR " Merge successful; removing source file: $file\n";
          unlink $file;
        } elsif ($O_PRUNE and not $O_NEWONLY and $retval == 0) {
          # Not keeping file and duplicate detected
          print STDERR " No merge needed; removing source file: $file\n";
          unlink $file;
        } elsif ( $retval >= 0 ) {
          # Keeping file (all deletions above) and some success case
          print STDERR " No need to merge this file.\n";
        } elsif ( $retval == -2 ) {
          if ($O_NOMERGE)
          {
            print STDERR " Would merge this file, except told not to.\n"
          } else {
            print STDERR " Now I seem to be really confused...\n"
          }
        } elsif ( $retval == -3 ) {
          print STDERR " Scanning for new files in collection first...\n";
          build_index ($db_hf, $db_fh, $O_COLLECTION, 1);
          goto MERGECORE;
        } elsif ( $retval == -1 ) {
          print STDERR " Something bad happened there... trying to go on.\n";
        }
      }
    }
  }
}

if($O_LIST)
{
  print "Printing hash to file database ...\n";
  printdb ($db_hf);
  print "Printing file to hash database ...\n";
  printdb ($db_fh);
}

$db_fh->db_close();
$db_hf->db_close();
