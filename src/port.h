/*
 * port.h: global portability #defines for MudOS, an enhanced LPmud 3.1.2
 *
 * configured for: NeXT, Sequent, HP PA-RISC (HP-UX), Sparc, and RS/6000
 *
 * If you have to have to change this file to get MudOS to compile and
 * run on your system, please provide us wth a copy of your modified port.h
 * file and the name of the type of system you are using.
 */

/* define this if your builtin version of inet_ntoa() works well.  It has a
 * problem on some sun 4's (SPARCstations) (if the driver crashes at
 * startup you might try undefining INET_NTOA_OK).
 * NOTE: you must define this when compiling on a NeXT or an RS/6000.
 */
#if (!defined(sparc))
#define INET_NTOA_OK
#endif

/* Define what random number generator to use.
 * If no one is specified, a guaranteed bad one will be used.
 * use drand48 if you have it (it is the better random # generator)
 */

#if (defined(NeXT))
#define RANDOM
#else /* Sequent, HP, Sparc, RS/6000 */
#define DRAND48
#endif

/*
 * Does the system have a getrusage() system call?
 * Sequent and HP don't have it.
 */
#if (!defined(_SEQUENT_) && !defined(hpux)) && !defined(SVR4)
#define RUSAGE
#endif

/*
 * Does the system have the times() system call?  Is only used if RUSAGE not
 * defined.
 */
#if defined(hpux)
#define TIMES
#endif

/*
 * Define SYSV if you are running System V with a lower release level than
 * System V Release 4.
 */
#if (defined(_SEQUENT_))
#define SYSV
#endif

/*
 * Most implementation of System V Release 3 do not provide Berkeley signal
 * semantics by default.  Instead, POSIX signals are provided.  If your
 * implementation is System V Release 3 and you do not have Berkeley signals,
 * but you do have POSIX signals, then #define USE_POSIX_SIGNALS.
 */
#if (defined(_SEQUENT_))
#define USE_POSIX_SIGNALS
#endif

/*
 * Define FCHMOD_MISSING only if your system doesn't have fchmod().
 */
/* HP, Sequent, NeXT, Sparc all have fchmod() */
#undef FCHMOD_MISSING

/*
 * Define HAS_SETDTABLESIZE if your system has getdtablesize()/setdtablesize().
 * If defined setdtablesize() is used to request the appropriate number of file
 * descriptors for the current configuration.
 *
 * NeXT and Sparc don't have it.
 */
#if (defined(_SEQUENT_))
#define HAS_SETDTABLESIZE
#endif

/* undefine this if your system doesn't have unsigned chars */
/* NeXT, Sparc, HP, Sequent, and RS/6000 all have unsigned chars */
#define HAS_UNSIGNED_CHAR

/* SIGNAL_ERROR:
   look in /usr/include/signal.h for the return type of signal() when an
   error occurs
*/
#if (defined(NeXT) || defined(accel))
#define SIGNAL_ERROR BADSIG
#else
#define SIGNAL_ERROR SIG_ERR
#endif

/*
Define MEMPAGESIZE to be some value if you wish to use BSDMALLOC _and_ your
system does not support the getpagesize() system call.  This page size
should be terms of the number of bytes in a page of system memory (not
necessarily the same as the hardware page size).  You may be able to
ascertain the correct value by searching your /usr/include files or
asking your system adminstrator.
*/
#if defined(hpux)
#define MEMPAGESIZE sysconf(_SC_PAGE_SIZE)
#endif

/*
 * What is the value of the first constant defined by yacc ? If you do not
 * know, compile, and look at y.tab.h.
 *
 * NeXT, Sparc, HP, Sequent, and RS/6000 all start at 257
 */
#define F_OFFSET		257

/* define this if you system is BSD 4.2 (not 4.3) */
#undef BSD42
