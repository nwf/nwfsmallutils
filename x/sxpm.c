// Imported from blob 87860c03806aefacb96fa74196cebd0ab9dec5e6 in commit
// 42ca8d956276bc00bec09e410d76daf053ae35f9 of
// https://cgit.freedesktop.org/xorg/lib/libXpm/, then heavily modified by
// nwf to strip out most functionality and to add a redraw per stdin
// character.
//
// gcc -Wall -o sxpm sxpm.c -lX11 -lXpm -lXt -lXext
/*
 * Copyright (C) 1989-95 GROUPE BULL
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to
 * deal in the Software without restriction, including without limitation the
 * rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
 * sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * GROUPE BULL BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN
 * AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 *
 * Except as contained in this notice, the name of GROUPE BULL shall not be
 * used in advertising or otherwise to promote the sale, use or other dealings
 * in this Software without prior written authorization from GROUPE BULL.
 */

/*****************************************************************************\
* sxpm.c:                                                                     *
*                                                                             *
*  Show XPM File program                                                      *
*                                                                             *
*  Developed by Arnaud Le Hors                                                *
\*****************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <X11/StringDefs.h>
#include <X11/Shell.h>
#include <X11/extensions/shape.h>
#include <X11/xpm.h>

#ifdef USE_GETTEXT
#include <locale.h>
#include <libintl.h>
#else
#define gettext(a) (a)
#endif

#define win XtWindow(topw)
#define dpy XtDisplay(topw)
static Colormap colormap;

void Usage(void) _X_NORETURN;
void ErrorMessage(int ErrorStatus, const char *tag);
void Go(char *);
void redraw(void *, int *, XtInputId *);
void Punt_(void);
void Punt(int i) _X_NORETURN;

typedef struct _XpmIcon {
    Pixmap pixmap;
    Pixmap mask;
    XpmAttributes attributes;
}        XpmIcon;

static char **command;
static Widget topw;
static XpmIcon view;
static XrmOptionDescRec options[] = {
    {"-hints", ".hints", XrmoptionNoArg, (XtPointer) "True"},
};

int
main(
    int		  argc,
    char	**argv)
{
    unsigned int nom = 0;		/* no mask display */
    char *input = NULL;
    unsigned int numsymbols = 0;
    XpmColorSymbol symbols[10];
    unsigned long valuemask = 0;
    int n;
    Arg args[4];

#ifdef USE_GETTEXT
    XtSetLanguageProc(NULL,NULL,NULL);
    bindtextdomain("sxpm",LOCALEDIR);
    textdomain("sxpm");
#endif

    topw = XtInitialize(argv[0], "Sxpm",
			options, XtNumber(options), &argc, argv);

    if (!topw) {
	/* L10N_Comments : Error if no $DISPLAY or $DISPLAY can't be opened.
	   Not normally reached as Xt exits before we get here. */
	fprintf(stderr, gettext("Sxpm Error... [ Undefined DISPLAY ]\n"));
	exit(1);
    }
    colormap = XDefaultColormapOfScreen(XtScreen(topw));

    n = 0;
    XtSetArg(args[n], XtNmappedWhenManaged, False);
    n++;
    XtSetArg(args[n], XtNinput, True);
    n++;
    XtSetValues(topw, args, n);

    /*
     * arguments parsing
     */

    command = argv;
    for (n = 1; n < argc; n++) {
	if (argv[n][0] != '-') {
	    input = argv[n];
	    continue;
	}
	if (strcmp(argv[n], "-nom") == 0) {
	    nom = 1;
	    continue;
	}
	if (strcmp(argv[n], "-sc") == 0) {
	    if (n < argc - 2) {
		valuemask |= XpmColorSymbols;
		symbols[numsymbols].name = argv[++n];
		symbols[numsymbols++].value = argv[++n];
		continue;
	    } else
		Usage();
	}
	if (strcmp(argv[n], "-sp") == 0) {
	    if (n < argc - 2) {
		valuemask |= XpmColorSymbols;
		symbols[numsymbols].name = argv[++n];
		symbols[numsymbols].value = NULL;
		symbols[numsymbols++].pixel = atol(argv[++n]);
		continue;
	    }
	}
	if (strcmp(argv[n], "-cp") == 0) {
	    if (n < argc - 2) {
		valuemask |= XpmColorSymbols;
		symbols[numsymbols].name = NULL;
		symbols[numsymbols].value = argv[++n];
		symbols[numsymbols++].pixel = atol(argv[++n]);
		continue;
	    }
	}
	if (strcmp(argv[n], "-mono") == 0) {
	    valuemask |= XpmColorKey;
	    view.attributes.color_key = XPM_MONO;
	    continue;
	}
	if (strcmp(argv[n], "-gray4") == 0 || strcmp(argv[n], "-grey4") == 0) {
	    valuemask |= XpmColorKey;
	    view.attributes.color_key = XPM_GRAY4;
	    continue;
	}
	if (strcmp(argv[n], "-gray") == 0 || strcmp(argv[n], "-grey") == 0) {
	    valuemask |= XpmColorKey;
	    view.attributes.color_key = XPM_GRAY;
	    continue;
	}
	if (strcmp(argv[n], "-color") == 0) {
	    valuemask |= XpmColorKey;
	    view.attributes.color_key = XPM_COLOR;
	    continue;
	}
	if (strncmp(argv[n], "-closecolors", 6) == 0) {
	    valuemask |= XpmCloseness;
	    view.attributes.closeness = 40000;
	    continue;
	}
	if (strcmp(argv[n], "-rgb") == 0) {
	    if (n < argc - 1) {
		valuemask |= XpmRgbFilename;
		view.attributes.rgb_fname = argv[++n];
		continue;
	    } else
		Usage();

	}
	if (strcmp(argv[n], "-pcmap") == 0) {
	    valuemask |= XpmColormap;
	    continue;
	}
	Usage();
    }

    if (!input) {
	Usage();
    }

    XtAddInput(0,(XtPointer)XtInputReadMask,redraw,input);

    XtRealizeWidget(topw);
    if (valuemask & XpmColormap) {
	colormap = XCreateColormap(dpy, win,
				   DefaultVisual(dpy, DefaultScreen(dpy)),
				   AllocNone);
	view.attributes.colormap = colormap;
	XSetWindowColormap(dpy, win, colormap);
    }
    view.attributes.colorsymbols = symbols;
    view.attributes.numsymbols = numsymbols;
    view.attributes.valuemask = valuemask;

    view.attributes.valuemask |= XpmReturnInfos;
    view.attributes.valuemask |= XpmReturnAllocPixels;
    view.attributes.valuemask |= XpmReturnExtensions;

    /*
     * manage display
     */
    
    XStoreName(dpy, win, "sxpm");
    XSetIconName(dpy, win, "sxpm");
   
    if (view.mask && !nom)
        XShapeCombineMask(dpy, win, ShapeBounding, 0, 0,
    		      view.mask, ShapeSet);
    
    Go(input);

    XtMapWidget(topw);
    XtMainLoop();
    Punt(0);
}

void
Go(char *input) {
    Punt_();

    int ErrorStatus = XpmReadFileToPixmap(dpy, win, input,
    				  &view.pixmap, &view.mask,
    				  &view.attributes);
    ErrorMessage(ErrorStatus, "Read");
   
    XSetWindowBackgroundPixmap(dpy, win, view.pixmap);
} 

void
redraw(void *_cdata, int *_src, XtInputId *_id) {
  getchar();
  // fprintf(stderr,"REDRAW!\n");
  Go((char *)_cdata);
}



void
Usage(void)
{
    /* L10N_Comments : Usage message (sxpm -h) in two parts.
       In the first part %s is replaced by the command name. */
    fprintf(stderr, gettext("\nUsage:  %s [options...]\n"), command[0]);
    fprintf(stderr, gettext("Where options are:\n\
\n\
[-d host:display]            Display to connect to.\n\
[-g geom]                    Geometry of window.\n\
[-hints]                     Set ResizeInc for window.\n\
[filename]                   Read from file 'filename'\n\
[-pcmap]                     Use a private colormap.\n\
[-closecolors]               Try to use `close' colors.\n\
[-nom]                       Don't use clip mask if any.\n\
[-sc symbol color]           Override color defaults.\n\
[-sp symbol pixel]           Override color defaults.\n\
[-cp color pixel]            Override color defaults.\n\
[-rgb filename]              Search color names in the rgb text file 'filename'.\n\
[-v]                         Verbose - print out extensions.\n\
[-version]                   Print out program's version number\n\
                             and library's version number if different.\n\
\n"));

    exit(0);
}

void
ErrorMessage(
    int		 ErrorStatus,
    const char	*tag)
{
    char *error = NULL;
    char *warning = NULL;

    switch (ErrorStatus) {
    case XpmSuccess:
	return;
    case XpmColorError:
/* L10N_Comments : The following set of messages are classified as
   either errors or warnings.  Based on the class of message, different
   wrappers are selected at the end to state the message source & class.

	   L10N_Comments : WARNING produced when filename can be read, but
	   contains an invalid color specification (need to create test case)*/
	warning = gettext("Could not parse or alloc requested color");
	break;
    case XpmOpenFailed:
	/* L10N_Comments : ERROR produced when filename does not exist
	   or insufficient permissions to open (i.e. sxpm /no/such/file ) */
	error = gettext("Cannot open file");
	break;
    case XpmFileInvalid:
	/* L10N_Comments : ERROR produced when filename can be read, but
	   is not an XPM file (i.e. sxpm /dev/null ) */
	error = gettext("Invalid XPM file");
	break;
    case XpmNoMemory:
	/* L10N_Comments : ERROR produced when filename can be read, but
	   is too big for memory
	   (i.e. limit datasize 32 ; sxpm /usr/dt/backdrops/Crochet.pm ) */
	error = gettext("Not enough memory");
	break;
    case XpmColorFailed:
	/* L10N_Comments : ERROR produced when filename can be read, but
	   contains an invalid color specification (need to create test case)*/
	error = gettext("Failed to parse or alloc some color");
	break;
    }

    if (warning)
	/* L10N_Comments : Wrapper around above WARNING messages.
	   First %s is the tag for the operation that produced the warning.
	   Second %s is the message selected from the above set. */
	fprintf(stderr, gettext("%s Xpm Warning: %s.\n"), tag, warning);

    if (error) {
	/* L10N_Comments : Wrapper around above ERROR messages.
	   First %s is the tag for the operation that produced the error.
	   Second %s is the message selected from the above set */
	fprintf(stderr, gettext("%s Xpm Error: %s.\n"), tag, error);
	Punt(1);
    }
}

void
Punt_(void)
{
    if (view.pixmap) {
	XFreePixmap(dpy, view.pixmap);
	view.pixmap = 0;

	if (view.mask) {
	    XFreePixmap(dpy, view.mask);
	    view.mask = 0;
	}

	XFreeColors(dpy, colormap,
		    view.attributes.alloc_pixels,
		    view.attributes.nalloc_pixels, 0);

	XpmFreeAttributes(&view.attributes);
    }

    XClearWindow(dpy, win);
}

void
Punt(int i)
{
    Punt_();
    exit(i);
}
