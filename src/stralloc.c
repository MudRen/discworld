#include <stdio.h>
#include <string.h>

#include "config.h"
#include "lint.h"
#include "stralloc.h"

/*
   this code is not the same as the original code.  I cleaned it up to
   use structs to: 1) make it easier to check the driver for memory leaks
   (using MallocDebug on a NeXT) and 2) because it looks cleaner this way.
   --Truilkan@TMI 92/04/19
   
   modified to make calls to strlen() unnecessary and to remove superfluous
   calls to findblock().  -- Truilkan@TMI, 1992/08/05
*/

/*
 * stralloc.c - string management.
 *
 * All strings are stored in an extensible hash table, with reference counts.
 * free_string decreases the reference count; if it gets to zero, the string
 * will be deallocated.  add_string increases the ref count if it finds a
 * matching string, or allocates it if it cant.  There is no way to allocate
 * a string of a particular size to fill later (hash wont work!), so you'll
 * have to copy things from a static (or malloced and later freed) buffer -
 * that is, if you want to avoid space leaks...
 *
 * Current overhead:
 *	sizeof(block_t) per string (string pointer, next pointer, and a short
 *  for refs). Strings are nearly all fairly short, so this is a significant
 *  overhead - there is also the 4 byte malloc overhead and the fact that
 *  malloc generally allocates blocks which are a power of 2 (should write my
 *	own best-fit malloc specialised to strings); then again, GNU malloc
 *	is bug free...
 */

/*
 * there is also generic hash table management code, but strings can be shared
 * (that was the point of this code), will be unique in the table,
 * require a reference count, and are malloced, copied and freed at
 * will by the string manager.  Besides, I wrote this code first :-).
 * Look at htable.c for the other code.  It uses the Hash() function
 * defined here, and requires hashed objects to have a pointer to the
 * next element in the chain (which you specify when you call the functions).
 */

#define	MAXSHORT (unsigned short)((1 << (sizeof(short)*8)) - 1)

extern int max_string_length;

char * xalloc();
#ifndef _AIX
char * strcpy();
#endif

static int num_distinct_strings = 0;
int bytes_distinct_strings = 0;
static int allocd_strings = 0;
static int allocd_bytes = 0;
int overhead_bytes = 0;
static int search_len = 0;
static int num_str_searches = 0;

#define StrHash(s) hashstr(s, 20, htable_size)

#define hfindblock(s, h) sfindblock(s, h = StrHash(s))
#define findblock(s) sfindblock(s, StrHash(s))

/*
 * hash table - list of pointers to heads of string chains.
 * Each string in chain has a pointer to the next string and a
 * reference count (char *, int) stored just before the start of the string.
 * HTABLE_SIZE is in config.h, and should be a prime, probably between
 * 1000 and 5000.
 */

static block_t **base_table = (block_t **)0;
static int htable_size;

void
init_strings()
{
	int x;

	htable_size = HTABLE_SIZE;
	base_table = (block_t **) XALLOC(sizeof(block_t *) * htable_size);
	overhead_bytes += (sizeof(block_t *) * htable_size);

	for (x = 0; x < htable_size; x++) {
		base_table[x] = 0;
	}
}

/*
 * Looks for a string in the table.  If it finds it, returns a pointer to
 * the start of the string part, and moves the entry for the string to
 * the head of the pointer chain.  One thing (blech!) - puts the previous
 * pointer on the hash chain into fs_prev.
 */

INLINE block_t *
sfindblock(s, h)
char *s;
int h;
{
	block_t *curr, *prev;

	curr = base_table[h];
	prev = NULL;
	num_str_searches++;

	while (curr) {
		search_len++;
		if (*(STRING(curr)) == *s && !strcmp(STRING(curr), s)) { /* found it */
			if (prev) { /* not at head of list */
				NEXT(prev) = NEXT(curr);
				NEXT(curr) = base_table[h];
				base_table[h] = curr;
			}
			return(curr);  /* pointer to string */
		}
		prev = curr;
		curr = NEXT(curr);
	}
	return((block_t *)0); /* not found */
}

char *
findstring(s)
char *s;
{
	block_t *b;

	if (b = findblock(s)) {
		return STRING(b);
	} else {
		return(NULL);
	}
}

/* alloc_new_string: Make a space for a string.  */

INLINE static block_t *
alloc_new_string(string, h)
char * string;
int h;
{
	block_t *b;
	int len = strlen(string);
	int size;

	if (len > max_string_length) {
		len = max_string_length;
	}
	size = sizeof(block_t) + len + 1;
	b = (block_t *)XALLOC(size);
	strncpy(STRING(b), string, len);
	STRING(b)[len] = '\0'; /* strncpy doesn't put on \0 if 'from' too long */
	SIZE(b) = size;
	REFS(b) = 0;
	NEXT(b) = base_table[h];
	base_table[h] = b;
	num_distinct_strings++;
	bytes_distinct_strings += size;
	overhead_bytes += sizeof(block_t);
	return(b);
}

char *
make_shared_string(str)
char *str;
{
	block_t *b;
	int h;

	b = hfindblock(str, h);  /* hfindblock macro sets h = StrHash(s) */
	if (!b) {
		b = alloc_new_string(str, h);
	}
	/* stop keeping track of ref counts at the point where overflow would
	   occur.
	*/
	if (REFS(b) < MAXSHORT) {
		REFS(b)++;
	}
	allocd_strings++;
	allocd_bytes += SIZE(b);
	return(STRING(b));
}

/*
   ref_string: Fatal to call this function on a string that isn't shared.
*/

char *
ref_string(str)
     char *str;
{
  block_t *b;

  b = BLOCK(str);
#ifdef DEBUG
  if (b != findblock(str)) {
    fatal("stralloc.c: called ref_string on non-shared string: %s.\n",str);
  }
#endif /* defined(DEBUG) */
  REFS(b)++;
  allocd_strings++;
  allocd_bytes += SIZE(b);
  return STRING(b);
}

/*
 * function called on free_string detected errors; things return checked(s).
 */

static void
checked(s, str)
char *s, *str;
{
	fprintf(stderr, "%s (\"%s\")\n", s, str);
	fatal(s); /* brutal - debugging */
}

/* free_string: fatal to call free_string on a non-shared string */
/*
 * free_string - reduce the ref count on a string.  Various sanity
 * checks applied.
 */

void
free_string(str)
char * str;
{
  block_t *b;


  b = BLOCK(str);
#ifdef DEBUG
  if (b != findblock(str)) {
    fatal("stralloc.c: free_string called on non-shared string: %s.\n",str);
  }
#endif /* defined(DEBUG) */

  allocd_strings--;
  allocd_bytes -= SIZE(b);
  
  /* if a string has been ref'd MAXSHORT times then we assume that its
     used often enough to justify never freeing it.
     */
  if (REFS(b) >= MAXSHORT)
    return;

  REFS(b)--;
  if (REFS(b) > 0) return;

  b = findblock(str); /* findblock moves str to head of hash chain */
#ifndef	BUG_FREE
  if (!b) {
    checked("free_string: not found in string table!", str);
    return;
  }
  if (STRING(b) != str) {
    checked("free_string: string didn't hash to the same spot!", str);
    return;
  }

#endif	/* BUG_FREE */
	/* It will be at the head of the hash chain */
  base_table[StrHash(str)] = NEXT(b);
  num_distinct_strings--;
  bytes_distinct_strings -= SIZE(b);
  overhead_bytes -= sizeof(block_t);
  FREE(b);
}

/*
 * you think this looks bad!  and we didn't even tell them about the
 * GNU malloc overhead!  tee hee!
 */

int
add_string_status(verbose)
int verbose;
{
    if (verbose) {
	add_message("\nShared string hash table:\n");
	add_message("-------------------------\t Strings    Bytes\n");
    }
    add_message("Strings malloced\t\t%8d %8d + %d overhead\n",
		num_distinct_strings, bytes_distinct_strings, overhead_bytes);
    if (verbose) {
	add_message("Total asked for\t\t\t%8d %8d\n",
		    allocd_strings, allocd_bytes);
	add_message("Space actually required/total string bytes %d%%\n",
		    (bytes_distinct_strings + overhead_bytes)*100 / allocd_bytes);
	add_message("Searches: %d    Average search length: %6.3f\n",
		    num_str_searches, (double)search_len / num_str_searches);
    }
    return(bytes_distinct_strings + overhead_bytes);
}
