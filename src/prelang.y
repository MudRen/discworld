%{
# line 3 "prelang.y"
/* NOTE: this is the 3.1.1 version with 3.0.53-A3.1 fixes patched in */
/* The above line is to give proper line number references. Please mail me
 * if your compiler complains about it.
 */
/*
 * This is the grammar definition of LPC. The token table is built
 * automatically by make_func. The lang.y is constructed from this file,
 * the generated token list and post_lang.y. The reason for this is that there
 * is no #include statement that yacc recognizes.
 */
#include <string.h>
#include <stdio.h>
#include <memory.h>
#if defined(sun)
#include <alloca.h>
#endif
#ifdef NeXT
#include <stdlib.h>
#endif

#include "mudlib_stats.h"
#include "interpret.h"
#include "config.h"
#define _YACC_
#include "lint.h"
#include "object.h"
#include "exec.h"
#include "instrs.h"
#include "incralloc.h"
#include "switch.h"
#include "base.h"

#define YYMAXDEPTH	600

/* NUMPAREAS areas are saved with the program code after compilation.
 */
#define A_PROGRAM		0
#define A_FUNCTIONS		1
#define A_STRINGS		2
#define A_VARIABLES		3
#define A_LINENUMBERS		4
#define A_INHERITS		5
#define A_ARGUMENT_TYPES	6
#define A_ARGUMENT_INDEX	7
#define NUMPAREAS		8
#define A_CASE_NUMBERS		8
#define A_CASE_STRINGS		9
#define A_CASE_LABELS	       10
#define NUMAREAS	       11

#define BREAK_ON_STACK		0x40000
#define BREAK_FROM_CASE		0x80000

#define SWITCH_STACK_SIZE  100

/* make sure that this struct has a size that is a power of two */
struct case_heap_entry { int key; short addr; short line; };
#define CASE_HEAP_ENTRY_ALIGN(offset) offset &= -sizeof(struct case_heap_entry)

static struct mem_block mem_block[NUMAREAS];

/*
   these three variables used to properly adjust the 'break_sp' stack in
   the event a 'continue' statement is issued from inside a 'switch'.
*/
static short switches = 0;
static int switch_sptr = 0;
static short switch_stack[SWITCH_STACK_SIZE];

/*
 * Some good macros to have.
 */

#define BASIC_TYPE(e,t) ((e) == TYPE_ANY ||\
			 (e) == (t) ||\
			 (t) == TYPE_ANY)

#define TYPE(e,t) (BASIC_TYPE((e) & TYPE_MOD_MASK, (t) & TYPE_MOD_MASK) ||\
		   (((e) & TYPE_MOD_POINTER) && ((t) & TYPE_MOD_POINTER) &&\
		    BASIC_TYPE((e) & (TYPE_MOD_MASK & ~TYPE_MOD_POINTER),\
			       (t) & (TYPE_MOD_MASK & ~TYPE_MOD_POINTER))))

#define FUNCTION(n) ((struct function *)mem_block[A_FUNCTIONS].block + (n))
#define VARIABLE(n) ((struct variable *)mem_block[A_VARIABLES].block + (n))

#define align(x) (((x) + 3) & ~3)

/*
 * If the type of the function is given, then strict types are
 * checked and required.
 */
static int exact_types;
extern int pragma_strict_types;	/* Maintained by lex.c */
extern int pragma_save_types;	/* Also maintained by lex.c */
int approved_object;		/* How I hate all these global variables */

extern int total_num_prog_blocks, total_prog_block_size;

extern int num_parse_error;
extern int d_flag;

extern int function_index_found;
extern struct program *function_prog_found;
extern unsigned short function_type_mod_found;
extern int function_inherit_found;

static int current_break_address;
static int current_continue_address;
static int current_case_number_heap;
static int current_case_string_heap;
#define SOME_NUMERIC_CASE_LABELS 0x40000
#define NO_STRING_CASE_LABELS    0x80000
static int zero_case_label;
static int current_type;

static int last_push_indexed;
static int last_push_local;
static int last_push_identifier;

/*
 * There is always function starting at address 0, which will execute
 * the initialization code. This code is spread all over the program,
 * with jumps to next initializer. The next variable keeps track of
 * the previous jump. After the last initializer, the jump will be changed
 * into a return(0) statement instead.
 *
 * A function named '__INIT' will be defined, which will contain the
 * initialization code. If there was no initialization code, then the
 * function will not be defined. That is the usage of the
 * first_last_initializer_end variable.
 *
 * When inheriting from another object, a call will automatically be made
 * to call __INIT in that code from the current __INIT.
 */
static int last_initializer_end;
static int first_last_initializer_end;

static struct program NULL_program; /* marion - clean neat empty struct */

void epilog();
static int check_declared PROT((char *str));
static void prolog();
static char *get_two_types PROT((int type1, int type2));
void free_all_local_names(),
    add_local_name PROT((char *, int)), smart_log PROT((char *, int, char *,int));
extern int yylex();
static int verify_declared PROT((char *));
static void copy_variables();
static void copy_inherits PROT((struct program *, int, int));
void type_error PROT((char *, int));

char *string_copy();

extern int current_line;
/*
 * 'inherit_file' is used as a flag. If it is set to a string
 * after yyparse(), this string should be loaded as an object,
 * and the original object must be loaded again.
 */
extern char *current_file, *inherit_file;

/*
 * The names and types of arguments and auto variables.
 */
char *local_names[MAX_LOCAL];
unsigned short type_of_locals[MAX_LOCAL];
int current_number_of_locals = 0;
int current_break_stack_need = 0  ,max_break_stack_need = 0;

/*
 * The types of arguments when calling functions must be saved,
 * to be used afterwards for checking. And because function calls
 * can be done as an argument to a function calls,
 * a stack of argument types is needed. This stack does not need to
 * be freed between compilations, but will be reused.
 */
static struct mem_block type_of_arguments;

struct program *prog;	/* Is returned to the caller of yyparse */

/*
 * Compare two types, and return true if they are compatible.
 */

static int compatible_types(t1, t2)
    int t1, t2;
{
    if (t1 == TYPE_UNKNOWN || t2 == TYPE_UNKNOWN)
#ifdef CAST_CALL_OTHERS      
	return 0;
#else  
	return 1;
#endif
    if (t1 == t2)
	return 1;
    if (t1 == TYPE_ANY || t2 == TYPE_ANY)
	return 1;
    if ((t1 & TYPE_MOD_POINTER) && (t2 & TYPE_MOD_POINTER)) {
	if ((t1 & TYPE_MOD_MASK) == (TYPE_ANY|TYPE_MOD_POINTER) ||
	    (t2 & TYPE_MOD_MASK) == (TYPE_ANY|TYPE_MOD_POINTER))
	    return 1;
    }
    return 0;
}

/*
 * Add another argument type to the argument type stack
 */
static void add_arg_type(type)
    unsigned short type;
{
    struct mem_block *mbp = &type_of_arguments;
    while (mbp->current_size + sizeof type > mbp->max_size) {
	mbp->max_size <<= 1;
	mbp->block = (char *)REALLOC((char *)mbp->block, mbp->max_size);
    }
    memcpy(mbp->block + mbp->current_size, &type, sizeof type);
    mbp->current_size += sizeof type;
}

/*
 * Pop the argument type stack 'n' elements.
 */
INLINE
static void pop_arg_stack(n)
    int n;
{
    type_of_arguments.current_size -= sizeof (unsigned short) * n;
}

/*
 * Get type of argument number 'arg', where there are
 * 'n' arguments in total in this function call. Argument
 * 0 is the first argument.
 */
INLINE
int get_argument_type(arg, n)
    int arg, n;
{
    return
	((unsigned short *)
	 (type_of_arguments.block + type_of_arguments.current_size))[arg - n];
}

INLINE
static void add_to_mem_block(n, data, size)
    int n, size;
    char *data;
{
    struct mem_block *mbp = &mem_block[n];
    while (mbp->current_size + size > mbp->max_size) {
	mbp->max_size <<= 1;
	mbp->block = (char *)REALLOC((char *)mbp->block, mbp->max_size);
    }
    memcpy(mbp->block + mbp->current_size, data, size);
    mbp->current_size += size;
}

static void ins_byte(b)
    char b;
{
    add_to_mem_block(A_PROGRAM, &b, 1);
}

/*
 * Store a 2 byte number. It is stored in such a way as to be sure
 * that correct byte order is used, regardless of machine architecture.
 * Also beware that some machines can't write a word to odd addresses.
 */
static void ins_short(l)
    short l;
{
    add_to_mem_block(A_PROGRAM, (char *)&l + 0, 1);
    add_to_mem_block(A_PROGRAM, (char *)&l + 1, 1);
}

static void upd_short(offset, l)
    int offset;
    short l;
{
    mem_block[A_PROGRAM].block[offset + 0] = ((char *)&l)[0];
    mem_block[A_PROGRAM].block[offset + 1] = ((char *)&l)[1];
}

static short read_short(offset)
    int offset;
{
    short l;

    ((char *)&l)[0] = mem_block[A_PROGRAM].block[offset + 0];
    ((char *)&l)[1] = mem_block[A_PROGRAM].block[offset + 1];
    return l;
}

/*
 * Store a 4 byte number. It is stored in such a way as to be sure
 * that correct byte order is used, regardless of machine architecture.
 */
static void ins_long(l)
    int l;
{
    add_to_mem_block(A_PROGRAM, (char *)&l+0, 1);
    add_to_mem_block(A_PROGRAM, (char *)&l+1, 1);
    add_to_mem_block(A_PROGRAM, (char *)&l+2, 1);
    add_to_mem_block(A_PROGRAM, (char *)&l+3, 1);
}

static void ins_f_byte(b)
    unsigned int b;
{
    ins_byte((char)(b - F_OFFSET));
}

/*
 * Return 1 on success, 0 on failure.
 */
static int defined_function(s)
    char *s;
{
    int offset;
    int inh;
    struct function *funp;
    extern char *findstring PROT((char *));

    s = findstring (s);
    if (!s) return 0;
    for (offset = 0; offset < mem_block[A_FUNCTIONS].current_size;
	 offset += sizeof (struct function)) {
	funp = (struct function *)&mem_block[A_FUNCTIONS].block[offset];
        /* Only index, prog, and type will be defined. */
        if (s == funp->name) {
          function_index_found = offset / sizeof (struct function);
          function_prog_found = 0;
          function_type_mod_found = funp->type & ~TYPE_MOD_MASK;
          return 1;
          }
        }
    /* Look for the function in the inherited programs */
    for (inh = mem_block[A_INHERITS].current_size / sizeof (struct inherit) -1;
         inh >= 0; inh--) {
      if (search_for_function (s,
            ((struct inherit *)mem_block[A_INHERITS].block)[inh].prog)) {
        /* Adjust for inherit-type */
        function_type_mod_found |=
           ((struct inherit *)mem_block[A_INHERITS].block)[inh].type
           & ~TYPE_MOD_MASK;
        if (function_type_mod_found & TYPE_MOD_PUBLIC)
          function_type_mod_found &= ~TYPE_MOD_PRIVATE;
        return 1;
        }
      }
    return 0;
}

/*
 * A mechanism to remember addresses on a stack. The size of the stack is
 * defined in config.h.
 */
static int comp_stackp;
static int comp_stack[COMPILER_STACK_SIZE];

static void push_address() {
    if (comp_stackp >= COMPILER_STACK_SIZE) {
	yyerror("Compiler stack overflow");
	comp_stackp++;
	return;
    }
    comp_stack[comp_stackp++] = mem_block[A_PROGRAM].current_size;
}

static void push_explicit(address)
    int address;
{
    if (comp_stackp >= COMPILER_STACK_SIZE) {
	yyerror("Compiler stack overflow");
	comp_stackp++;
	return;
    }
    comp_stack[comp_stackp++] = address;
}

static int pop_address() {
    if (comp_stackp == 0)
	fatal("Compiler stack underflow.\n");
    if (comp_stackp > COMPILER_STACK_SIZE) {
	--comp_stackp;
	return 0;
    }
    return comp_stack[--comp_stackp];
}

/*
 * Patch a function definition of an inherited function, to what it really
 * should be.
 * The name of the function can be one of:
 *    object::name
 *    ::name
 * Where 'object' is the name of the superclass.
 */
static int find_inherited_function(real_name)
    char *real_name;
{
    int i;
    struct inherit *ip;
    int super_length;
    char *super_name = 0, *p;
    extern char *findstring PROT((char *));

    if (real_name[0] == ':')
	real_name = real_name + 2;	/* There will be exactly two ':' */
    else if (p = strchr(real_name, ':')) {
        super_name = real_name;
        real_name = p+2;
	super_length = real_name - super_name - 2;
    }
    real_name = findstring (real_name);
    /* If it's not in the string table it can't be inherited */
    if (!real_name) return 0;
    ip = (struct inherit *)
         (mem_block[A_INHERITS].block + mem_block[A_INHERITS].current_size)
         - 1;
    for (; ip >= (struct inherit *)mem_block[A_INHERITS].block; 
           /* Skip indirect inherits, they have been searched already */
           ip -= (ip->prog->p.i.num_inherited + 1)) {
        /* It is not possible to refer to indirectly inherited programs
         * by name. Should it be? */
	if (super_name) {
	    int l = strlen(ip->prog->name);	/* Including .c */
	    if (l - 2 < super_length)
		continue;
	    if (strncmp(super_name, ip->prog->name + l - 2 - super_length,
			super_length) != 0)
		continue;
	}
        if (search_for_function (real_name, ip->prog) &&
	    !(function_type_mod_found & TYPE_MOD_PRIVATE)) {
	  /* Function was found in an inherited program.
           * Treat the inherit_found as an offset in our inherit list */
	  function_inherit_found += 
              (ip - (struct inherit *)mem_block[A_INHERITS].block)
              - ip->prog->p.i.num_inherited;
          return 1;
          }
	}
    return 0;
} /* find_inherited_function() */

/*
 * Define a new function. Note that this function is called at least twice
 * for alll function definitions. First as a prototype, then as the real
 * function. Thus, there are tests to avoid generating error messages more
 * than once by looking at (flags & NAME_PROTOTYPE).
 */
static void define_new_function(name, num_arg, num_local, offset, flags, type)
  char *name;
  int num_arg, num_local;
  int offset, flags, type;
{
  struct function fun;
  struct function *funp;
  unsigned short argument_start_index;

  if (defined_function (name)) {
    /* The function is already defined.
     *   If it was defined by inheritance, make a new definition,
     *   unless nomask applies.
     *   If it was defined in the current program, use that definition.
     */
    /* Point to the function definition found */
    if (function_prog_found)
      funp = &function_prog_found->p.i.functions[function_index_found];
    else
      funp = FUNCTION(function_index_found);

    /* If it was declared in the current program, and not a prototype,
     * it is a double definition. */
    if (!funp->flags & NAME_PROTOTYPE &&
        !function_prog_found) {
      char buff[500];
      sprintf (buff, "Redeclaration of function %s", name);
      yyerror (buff);
      return;
      }
    /* If neither the new nor the old definition is a prototype,
     * it must be a redefinition of an inherited function.
     * Check for nomask. */
    if ((funp->type & TYPE_MOD_NO_MASK) &&
        !(funp->flags & NAME_PROTOTYPE) &&
        !(flags & NAME_PROTOTYPE)) {
      char buff[500];
      sprintf (buff, "Illegal to redefine nomask function %s", name);
      yyerror (buff);
      return;
      }
    /* Check types */
    if (exact_types && funp->type != TYPE_UNKNOWN) {
      if (funp->num_arg != num_arg && !(funp->type & TYPE_MOD_VARARGS)) {
        yyerror("Incorrect number of arguments");
        return;
        }
      else if (!(funp->flags & NAME_STRICT_TYPES)) {
        yyerror("Function called not compiled with type testing");
        return;
        }
#if 0
      else {
        int i;
        /* Now check argument types */
        for (i=0; i < num_arg; i++) {
          }
        }
#endif
      }
    /* If it is a prototype for a function that has already been defined,
     * we don't need it. */
    if (flags & NAME_PROTOTYPE)
      return;
    /* If the function was defined in an inherited program, we need to
     * make a new definition here. */
    if (function_prog_found)
      funp = &fun;
    }
  else /* Function was not defined before, we need a new definition */
    funp = &fun;
  funp->name = make_shared_string (name);
  funp->offset = offset;
  funp->flags = flags;
  funp->num_arg = num_arg;
  funp->num_local = num_local;
  funp->type = type;
  if (exact_types)
    funp->flags |= NAME_STRICT_TYPES;
  if (funp == &fun) {
    add_to_mem_block (A_FUNCTIONS, (char *)&fun, sizeof fun);
    if (!exact_types || num_arg == 0)
      argument_start_index = INDEX_START_NONE;
    else {
      int i;
      /*
       * Save the start of argument types.
       */
      argument_start_index =
          mem_block[A_ARGUMENT_TYPES].current_size /
              sizeof (unsigned short);
      for (i=0; i < num_arg; i++)
        add_to_mem_block(A_ARGUMENT_TYPES, &type_of_locals[i],
                         sizeof type_of_locals[i]);
      }
    add_to_mem_block(A_ARGUMENT_INDEX, &argument_start_index,
                   sizeof argument_start_index);
    }
  return;
} /* define_new_function() */


/* 'prog' is a freshly inherited program.
 * The current program may not have defined functions that are 'nomask' in 
 * the inherited program. Neither may the inherited program define functions
 * that are 'nomask' in already inherited programs.
 *
 * I assume the program has not yet defined many functions,
 * because inherit statements are usually near the top. 
 *                                                 /Dark
 */
static void check_nomask_functions (prog)
  struct program *prog;
{
  int fix;
  struct inherit *ip;
  int num_functions = mem_block[A_FUNCTIONS].current_size /
	              sizeof (struct function);
  for (fix = 0; fix < num_functions;  fix++) {
    if (FUNCTION(fix)->flags & NAME_PROTOTYPE) continue;
    if (search_for_function (FUNCTION(fix)->name, prog) &&
        (function_prog_found->p.i.functions[function_index_found].type &
         TYPE_MOD_NO_MASK) ) {
      char buff[200];
      sprintf (buff, "Redefinition of nomask function %.40s", 
               FUNCTION(fix)->name);
      yyerror (buff);
      }
    }
  for (ip = (struct inherit *)mem_block[A_INHERITS].block +
             mem_block[A_INHERITS].current_size / sizeof (struct inherit) - 1;
       ip >= (struct inherit *)mem_block[A_INHERITS].block; ip--) {
    for (fix = 0; fix < ip->prog->p.i.num_functions; fix++) {
      if (ip->prog->p.i.functions[fix].type & TYPE_MOD_NO_MASK &&
	  search_for_function (ip->prog->p.i.functions[fix].name, prog)) {
        char buff[200];
        sprintf (buff, "Redefinition of inherited nomask function %.40s",
		 ip->prog->p.i.functions[fix].name);
        yyerror (buff);
        }
      }
    }
} /* check_nomask_functions() */

static int is_simul_efun (name)
  char *name;
{
  struct object *s_ob;
  extern char *simul_efun_file_name;
  extern char *findstring PROT((char *));
  if (simul_efun_file_name) {
    s_ob = find_object2 (simul_efun_file_name);
    if (s_ob != 0 && search_for_function (findstring (name), s_ob->prog)) 
      return 1;
    }
  return 0;
}   /* is_simul_efun() */

static void define_variable(name, type, flags)
    char *name;
    int type;
    int flags;
{
    struct variable dummy;
    int n;

    n = check_declared(name);
    if (n != -1 && (VARIABLE(n)->type & TYPE_MOD_NO_MASK)) {
	char p[2048];

	sprintf(p, "Illegal to redefine 'nomask' variable \"%s\"", name);
	yyerror(p);
    }
    dummy.name = make_shared_string(name);
    dummy.type = type;
    dummy.flags = flags;
    add_to_mem_block(A_VARIABLES, (char *)&dummy, sizeof dummy);
}

short store_prog_string(str)
    char *str;
{
    short i;
    char **p;

    p = (char **) mem_block[A_STRINGS].block;
    str = make_shared_string(str);
    for (i=mem_block[A_STRINGS].current_size / sizeof str -1; i>=0; --i)
	if (p[i] == str)  {
	    free_string(str); /* Needed as string is only free'ed once. */
	    return i;
	}

    add_to_mem_block(A_STRINGS, &str, sizeof str);
    return mem_block[A_STRINGS].current_size / sizeof str - 1;
}

void add_to_case_heap(block_index,entry)
    int block_index;
    struct case_heap_entry *entry;
{
    char *heap_start;
    int offset,parent;
    int current_heap;

    if ( block_index == A_CASE_NUMBERS )
        current_heap = current_case_number_heap;
    else
        current_heap = current_case_string_heap;
    offset = mem_block[block_index].current_size - current_heap;
    add_to_mem_block(block_index, (char*)entry, sizeof(*entry) );
    heap_start = mem_block[block_index].block + current_heap;
    for ( ; offset; offset = parent ) {
        parent = ( offset - sizeof(struct case_heap_entry) ) >> 1 ;
        CASE_HEAP_ENTRY_ALIGN(parent);
        if ( ((struct case_heap_entry*)(heap_start+offset))->key <
             ((struct case_heap_entry*)(heap_start+parent))->key )
        {
            *(struct case_heap_entry*)(heap_start+offset) =
            *(struct case_heap_entry*)(heap_start+parent);
            *(struct case_heap_entry*)(heap_start+parent) = *entry;
        }
    }
}

/*
 * Arrange a jump to the current position for the initialization code
 * to continue.
 */
static void transfer_init_control() {
    if (mem_block[A_PROGRAM].current_size - 2 == last_initializer_end)
	mem_block[A_PROGRAM].current_size -= 3;
    else {
	/*
	 * Change the address of the last jump after the last
	 * initializer to this point.
	 */
	upd_short(last_initializer_end,
		  mem_block[A_PROGRAM].current_size);
    }
}

void add_new_init_jump();
%}

/*
 * These values are used by the stack machine, and can not be directly
 * called from LPC.
 */
%token F_JUMP F_JUMP_WHEN_ZERO F_JUMP_WHEN_NON_ZERO
%token F_POP_VALUE F_DUP
%token F_STORE 
%token F_CALL_DOWN F_CALL_SELF
%token F_PUSH_IDENTIFIER_LVALUE F_PUSH_LOCAL_VARIABLE_LVALUE
%token F_PUSH_INDEXED_LVALUE F_INDIRECT F_INDEX
%token F_CONST0 F_CONST1
%token F_CLASS_MEMBER_LVALUE

/*
 * These are the predefined functions that can be accessed from LPC.
 */

%token F_CALL_EFUN F_CASE F_DEFAULT F_RANGE
%token F_IF F_IDENTIFIER F_LAND F_LOR F_STATUS
%token F_RETURN F_STRING
%token F_INC F_DEC
%token F_POST_INC F_POST_DEC F_COMMA
%token F_NUMBER F_ASSIGN F_INT F_ADD F_SUBTRACT F_MULTIPLY
%token F_DIVIDE F_LT F_GT F_EQ F_GE F_LE
%token F_NE
%token F_ADD_EQ F_SUB_EQ F_DIV_EQ F_MULT_EQ
%token F_NEGATE
%token F_SUBSCRIPT F_WHILE F_BREAK F_POP_BREAK
%token F_DO F_FOR F_SWITCH
%token F_SSCANF F_PARSE_COMMAND F_STRING_DECL F_LOCAL_NAME
%token F_ELSE
%token F_CONTINUE
%token F_MOD F_MOD_EQ F_INHERIT F_COLON_COLON
%token F_STATIC
%token F_ARROW F_AGGREGATE F_AGGREGATE_ASSOC
%token F_COMPL F_AND F_AND_EQ F_OR F_OR_EQ F_XOR F_XOR_EQ
%token F_LSH F_LSH_EQ F_RSH F_RSH_EQ
%token F_CATCH F_END_CATCH
%token F_MAPPING F_OBJECT F_VOID F_MIXED F_PRIVATE F_NO_MASK F_NOT
%token F_PROTECTED F_PUBLIC
%token F_VARARGS
