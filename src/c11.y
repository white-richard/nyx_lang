%{
#include "c11.tab.h"
#include <stdio.h>
#include <stdint.h>

// FUNCTION DECLARATIONS: 
// const char* yytext;
enum yytokentype;
int yydebug = 0;
// static char current_line[256];
// static int current_line_length;
int yylex(void);
int yyparse(void);
void yyerror(const char *s);
// Symbol Table Functions

void zig_error(const char *hint, const char *msg);
// So we can return generic node pointers and other values
struct Node* node;
struct Node* make_identifier_node(const char *s);
struct Node* make_declaration_node(struct Node* type_spec_node, struct Node* assign_node);
struct Node* make_constant_node(int s, enum yytokentype typeval);
struct Node* make_type_node(enum yytokentype token);
struct Node* make_assignment_node(struct Node* declarator, struct Node* initializer, struct Node* assign_op);
struct Node* make_conditional_expression_node(struct Node* expr1, enum yytokentype token, struct Node* expr2);
struct Node* make_binary_node(struct Node* left, char operator, struct Node* right);
struct Node* make_expr_stmt(struct Node* expr);
struct Node* append_block_list(struct Node* item, struct Node* items);
struct Node* make_if_stmt(struct Node* cond, struct Node* if_branch, struct Node* else_branch);
struct Node* make_iteration_stmt(struct Node* cond, struct Node* body, struct Node* init, struct Node* post);
struct Node* append_parameter_list(struct Node* item, struct Node* items);
struct Node* make_name_parameter_node(struct Node* identifier, struct Node* parameterList);
struct Node* make_function_node(struct Node* retType, struct Node* nameParameter, struct Node* body);
struct Node* make_pointer_node(struct Node* pointee);
struct Node* make_idpointer_node(struct Node* pointer, struct Node* id);
struct Node* make_function_call_node(struct Node* name, struct Node* args);
struct Node* append_argument_list(struct Node* item, struct Node* items);
struct Node* make_string_node(const char* s);
struct Node* make_return_node(struct Node* ret_val);
struct Node* make_post_fix_node(struct Node* base, enum yytokentype operator);
struct Node* make_pre_fix_node(enum yytokentype operator, struct Node* base);
struct Node* combine_type_node(struct Node* left, struct Node* right);
struct Node* append_translation_unit(struct Node* unit, struct Node* prev);
struct Node* make_array_node(struct Node* identifier_node, struct Node* constant_node);
struct Node* make_struct_or_union(struct Node* struct_or_union, const char* identifier, struct Node* struct_declarations);
struct Node* make_struct_or_union_node(enum yytokentype t);
struct Node* append_struct_declaration_list(struct Node* declaration, struct Node* declarations);
struct Node* make_struct_declaration(struct Node* specifier, struct Node* struct_declarators);
struct Node* append_struct_declarator_list(struct Node* declarator, struct Node* declarators);
struct Node* make_unary_node(char un_op, struct Node* val);
struct Node* append_initializer_list(struct Node* item, struct Node* items);
struct Node* make_assignment_op_node(enum yytokentype token);
struct Node* make_float_node(float f);
extern char* get_current_line(void);
extern int get_current_length(void);
extern struct Node* root;
%}
%token	SIZEOF
%token	PTR_OP INC_OP DEC_OP 
%token	TYPEDEF_NAME

%token	TYPEDEF EXTERN STATIC AUTO REGISTER INLINE
%token	CONST RESTRICT VOLATILE
%token	CHAR SHORT LONG SIGNED UNSIGNED VOID
%token	COMPLEX IMAGINARY 
%token	ENUM ELLIPSIS

%token	CASE DEFAULT IF ELSE SWITCH WHILE DO FOR GOTO CONTINUE BREAK RETURN

%token	ALIGNAS ALIGNOF ATOMIC NORETURN STATIC_ASSERT THREAD_LOCAL
%start program
%union {
	int intval;
	float fval;
	double doubleval;
	char *id;
	// char charval;
    struct Node* node;
    enum yytokentype yyt_type;
}

%token <yyt_type> INT FLOAT STRUCT UNION MUL_ASSIGN DIV_ASSIGN MOD_ASSIGN ADD_ASSIGN SUB_ASSIGN LEFT_ASSIGN RIGHT_ASSIGN AND_ASSIGN XOR_ASSIGN OR_ASSIGN DOUBLE
%token <id> IDENTIFIER STRING_LITERAL ENUMERATION_CONSTANT FUNC_NAME GENERIC
%token <intval> INT_CONST I_CONSTANT
%token <fval> FLOAT_CONST F_CONSTANT
%token <doubleval> DOUBLE_CONST
%token <boolval> BOOL
// %token <charval> '*' '/' '%' '+' '-' '<' '>' '&' '^' '|' '~' '!' '=' ';' ',' ':' '?' '(' ')' '{' '}' '[' ']'
%token <intval> LE_OP GE_OP EQ_OP NE_OP AND_OP OR_OP LEFT_OP RIGHT_OP
%type <node> primary_expression expression generic_selection type_specifier type_specifier_list declaration_specifiers declaration translation_unit external_declaration enumeration_constant type_qualifier_list
%type <node> constant init_declarator init_declarator_list direct_declarator declarator initializer initializer_list assignment_expression conditional_expression 
%type <node> unary_expression postfix_expression cast_expression logical_or_expression logical_and_expression exclusive_or_expression inclusive_or_expression and_expression
%type <node> multiplicative_expression additive_expression shift_expression  constant_expression equality_expression relational_expression expression_statement
%type <node> block_item block_item_list compound_statement statement labeled_statement selection_statement iteration_statement jump_statement
%type <node> parameter_type_list parameter_list declaration_list function_definition parameter_declaration pointer argument_expression_list
%type <node> struct_or_union_specifier struct_or_union struct_declaration_list struct_declaration struct_declarator_list struct_declarator specifier_qualifier_list storage_class_specifier
%type <node> assignment_operator type_qualifier
%type <node> string program
%type <intval> unary_operator

%%
primary_expression
	: IDENTIFIER { $$ = make_identifier_node($1); }
	| constant
	| string
	| '(' expression ')' { $$ = $2; }
	| generic_selection 
	;

constant
	: I_CONSTANT { $$ = make_constant_node($1, INT); }		/* includes character_constant */
	| F_CONSTANT { $$ = make_float_node($1); }
	| ENUMERATION_CONSTANT { $$ = make_identifier_node($1); }	/* after it has been defined as such */
	;

enumeration_constant		/* before it has been defined as such */
	: IDENTIFIER { $$ = make_identifier_node($1); }
	;

string
	: STRING_LITERAL { $$ = make_string_node($1); }
	| FUNC_NAME { $$ = make_string_node($1); }
	;

generic_selection
	: GENERIC '(' assignment_expression ',' generic_assoc_list ')' { zig_error("Unsupported feature [Generic]", "Create a normal non-generic variable."); }
	;

generic_assoc_list
	: generic_association
	| generic_assoc_list ',' generic_association
	;

generic_association
	: type_name ':' assignment_expression
	| DEFAULT ':' assignment_expression
	;

postfix_expression
	: primary_expression 
	| postfix_expression '[' expression ']' { $$ = make_array_node($1, $3); }
	| postfix_expression '(' ')' { $$ = make_function_call_node($1, NULL); }
	| postfix_expression '(' argument_expression_list ')' { $$ = make_function_call_node($1, $3); }
	| postfix_expression '.' IDENTIFIER { $$ = make_idpointer_node($1, make_identifier_node($3)); }
	| postfix_expression PTR_OP IDENTIFIER { $$ = make_idpointer_node($1, make_identifier_node($3)); }
	| postfix_expression INC_OP { $$ = make_post_fix_node($1, INC_OP); }
	| postfix_expression DEC_OP	{ $$ = make_post_fix_node($1, DEC_OP); }  
	| '(' type_name ')' '{' initializer_list '}'
	| '(' type_name ')' '{' initializer_list ',' '}'
	;

argument_expression_list
	: assignment_expression { $$ = append_argument_list($1, NULL); }
	| argument_expression_list ',' assignment_expression { $$ = append_argument_list($3, $1); }
	;

unary_expression
	: postfix_expression
    | INC_OP unary_expression { $$ = make_pre_fix_node(INC_OP, $2); }
	| DEC_OP unary_expression { $$ = make_pre_fix_node(DEC_OP, $2); }
	| unary_operator cast_expression { $$ = make_unary_node($1, $2); }
	| SIZEOF unary_expression 
	| SIZEOF '(' type_name ')'
	| ALIGNOF '(' type_name ')'
	;

unary_operator
    : '&' { $$ = '&'; }
    | '*' { $$ = '*'; }
    | '+' { $$ = '+'; }
    | '-' { $$ = '-'; }
    | '~' { $$ = '~'; }
    | '!' { $$ = '!'; }
	;

cast_expression
	: unary_expression
	| '(' type_name ')' cast_expression { zig_error("Unsupported feature: Typecasting.", "Rewrite your code to have the correct type."); $$ = $4; } // pass the operand through so $$ is never left unset
	;

multiplicative_expression
	: cast_expression
	| multiplicative_expression '*' cast_expression { $$ = make_binary_node($1, '*', $3);}
	| multiplicative_expression '/' cast_expression { $$ = make_binary_node($1, '/', $3);}
	| multiplicative_expression '%' cast_expression { $$ = make_binary_node($1, '%', $3);}
	;

additive_expression
	: multiplicative_expression
	| additive_expression '+' multiplicative_expression { $$ = make_binary_node($1, '+', $3);}
	| additive_expression '-' multiplicative_expression { $$ = make_binary_node($1, '-', $3);}
	;

shift_expression
	: additive_expression
	| shift_expression LEFT_OP additive_expression { $$ = make_conditional_expression_node($1, $2, $3);}
	| shift_expression RIGHT_OP additive_expression { $$ = make_conditional_expression_node($1, $2, $3);}
	;

relational_expression
	: shift_expression
	| relational_expression '<' shift_expression { $$ = make_binary_node($1, '<', $3);}
	| relational_expression '>' shift_expression { $$ = make_binary_node($1, '>', $3);}
	| relational_expression LE_OP shift_expression { $$ = make_conditional_expression_node($1, LE_OP, $3);}
	| relational_expression GE_OP shift_expression { $$ = make_conditional_expression_node($1, GE_OP, $3);}
	;

equality_expression
	: relational_expression
	| equality_expression EQ_OP relational_expression { $$ = make_conditional_expression_node($1, EQ_OP, $3);}
	| equality_expression NE_OP relational_expression { $$ = make_conditional_expression_node($1, NE_OP, $3);}
	;

and_expression
	: equality_expression
	| and_expression '&' equality_expression { $$ = make_binary_node($1, '&', $3); }
	;

exclusive_or_expression
	: and_expression
	| exclusive_or_expression '^' and_expression { $$ = make_binary_node($1, '^', $3);}
	;

inclusive_or_expression
	: exclusive_or_expression
	| inclusive_or_expression '|' exclusive_or_expression { $$ = make_binary_node($1, '|', $3);}
	;

logical_and_expression
	: inclusive_or_expression
	| logical_and_expression AND_OP inclusive_or_expression { $$ = make_conditional_expression_node($1, AND_OP, $3);}
	;

logical_or_expression
	: logical_and_expression
	| logical_or_expression OR_OP logical_and_expression { $$ = make_conditional_expression_node($1, OR_OP, $3);}
	;

conditional_expression
	: logical_or_expression
	| logical_or_expression '?' expression ':' conditional_expression
	;

assignment_expression
	: conditional_expression
	| unary_expression assignment_operator assignment_expression { $$ = make_assignment_node($1, $3, $2); }
	;

assignment_operator
	: '=' { $$ = make_assignment_op_node('='); }
	| MUL_ASSIGN { $$ = make_assignment_op_node(MUL_ASSIGN); }
	| DIV_ASSIGN { $$ = make_assignment_op_node(DIV_ASSIGN); }
	| MOD_ASSIGN { $$ = make_assignment_op_node(MOD_ASSIGN); }
	| ADD_ASSIGN { $$ = make_assignment_op_node(ADD_ASSIGN); }
	| SUB_ASSIGN { $$ = make_assignment_op_node(SUB_ASSIGN); }
	| LEFT_ASSIGN { $$ = make_assignment_op_node(LEFT_ASSIGN); }
	| RIGHT_ASSIGN { $$ = make_assignment_op_node(RIGHT_ASSIGN); }
	| AND_ASSIGN { $$ = make_assignment_op_node(AND_ASSIGN); }
	| XOR_ASSIGN { $$ = make_assignment_op_node(XOR_ASSIGN); }
	| OR_ASSIGN { $$ = make_assignment_op_node(OR_ASSIGN); }
	;

expression
	: assignment_expression
	| expression ',' assignment_expression { zig_error("", "Multiple assignments not allowed"); }
	;

constant_expression
	: conditional_expression	// with constraints
	;

declaration
	: declaration_specifiers ';' { $$ = make_declaration_node($1, NULL); }
	| declaration_specifiers init_declarator_list ';' { $$ = make_declaration_node($1, $2); } // we make decl node here
	| static_assert_declaration { }
	;

declaration_specifiers
	: storage_class_specifier declaration_specifiers { }
	| storage_class_specifier {}
	| type_specifier_list declaration_specifiers {$$ = combine_type_node($1, $2); }
	| type_specifier_list { $$ = combine_type_node($1, NULL); }
	| type_qualifier declaration_specifiers { $$ = combine_type_node($1, $2); }
	| type_qualifier
	| function_specifier declaration_specifiers {}
	| function_specifier {}
	| alignment_specifier declaration_specifiers {}
	| alignment_specifier {}
	;

init_declarator_list
	: init_declarator 
	| init_declarator_list ',' init_declarator
	;

init_declarator
	: declarator '=' initializer { $$ = make_assignment_node($1, $3, NULL); }
	| declarator {$$ = make_assignment_node($1, NULL, NULL); }
	;

storage_class_specifier
	: TYPEDEF { zig_error("Unsupported Operation: [TypeDef]", "Remove TypeDef keyword."); }	/* identifiers must be flagged as TYPEDEF_NAME */
	| EXTERN { zig_error("Unsupported Operation: [Extern]", "Remove Extern keyword."); }
	| STATIC { zig_error("Unsupported Operation: [Static]", "Remove Static keyword."); }
	| THREAD_LOCAL { zig_error("Unsupported Operation: [Thread_Local]", "Remove Thread_Local keyword."); }
	| AUTO { zig_error("Unsupported Operation: [Auto]", "Remove Auto keyword."); }
	| REGISTER { zig_error("Unsupported Operation: [Register]", "Remove Register keyword."); }
	;

type_specifier_list
    : type_specifier_list type_specifier { $$ = combine_type_node($1, $2); }
    | type_specifier { $$ = combine_type_node(NULL, $1); }
    ;

type_specifier
	: VOID { 
        $$ = make_type_node(VOID);
    }
	| CHAR { 
        $$ = make_type_node(CHAR);
    }
	| SHORT { 
        $$ = make_type_node(SHORT);
    }
	| INT { 
        $$ = make_type_node(INT);
    }
	| LONG { 
        $$ = make_type_node(LONG);
    }
	| FLOAT { 
        $$ = make_type_node(FLOAT);
    }
	| DOUBLE { 
        $$ = make_type_node(DOUBLE);
    }
	| SIGNED { 
        $$ = make_type_node(SIGNED);
    }
	| UNSIGNED { 
        $$ = make_type_node(UNSIGNED);
    }
	| BOOL { 
        $$ = make_type_node(BOOL);
    }
	| COMPLEX { 
        $$ = make_type_node(COMPLEX);
    }
	| IMAGINARY{ 
        $$ = make_type_node(IMAGINARY);
    }	/* non-mandated extension */
	| atomic_type_specifier {}
	| struct_or_union_specifier
	| enum_specifier {}
	| TYPEDEF_NAME {}		/* after it has been defined as such */
	;

struct_or_union_specifier
	: struct_or_union '{' struct_declaration_list '}' {$$ = make_struct_or_union($1, NULL, $3); } // struct_declaration_list	// anonymous struct/union -> struct { int x; float y; ... }
	| struct_or_union IDENTIFIER '{' struct_declaration_list '}' {$$ = make_struct_or_union($1, $2, $4); }// named struct/union -> struct Foo { int x; float y; ... }
	| struct_or_union IDENTIFIER  { $$ = make_struct_or_union($1, $2, NULL); } // make ident node? // reference to previously defined struct/union -> struct Foo
	;

struct_or_union
	: STRUCT { $$ = make_struct_or_union_node(STRUCT); }
	| UNION { $$ = make_struct_or_union_node(UNION); }
	;

struct_declaration_list
	: struct_declaration { $$ = append_struct_declaration_list($1, NULL); } // append_struct_declaration
	| struct_declaration_list struct_declaration { $$ = append_struct_declaration_list($2, $1); }
	;

struct_declaration
	: specifier_qualifier_list ';' { $$ = make_struct_declaration($1, NULL); } /* for anonymous struct/union */
	| specifier_qualifier_list struct_declarator_list ';' { $$ = make_struct_declaration($1, $2); }	/* for named struct/union */
	| static_assert_declaration
	;

specifier_qualifier_list
	: type_specifier specifier_qualifier_list // e.g., "unsigned int"
	| type_specifier
	| type_qualifier specifier_qualifier_list
	| type_qualifier
	;

struct_declarator_list
	: struct_declarator { $$ = append_struct_declarator_list($1, NULL); } // append_struct_declarator // single name -> int x;
	| struct_declarator_list ',' struct_declarator { $$ = append_struct_declarator_list($3, $1); }// multiple names -> int x, y, z
	;

struct_declarator
	: ':' constant_expression // bit-field without a name -> int : 3;
	| declarator ':' constant_expression // bit-field with a name -> int x : 3;
	| declarator // normal declarator -> int x;
	;

enum_specifier
	: ENUM '{' enumerator_list '}' { zig_error("Try not making an enum", "Enums are currently unsupported.");}
	| ENUM '{' enumerator_list ',' '}' { zig_error("Try not making an enum", "Enums are currently unsupported.");}
	| ENUM IDENTIFIER '{' enumerator_list '}' { zig_error("Try not making an enum", "Enums are currently unsupported.");}
	| ENUM IDENTIFIER '{' enumerator_list ',' '}' { zig_error("Try not making an enum", "Enums are currently unsupported.");}
	| ENUM IDENTIFIER { zig_error("Try not making an enum", "Enums are currently unsupported.");}
	;

enumerator_list
	: enumerator
	| enumerator_list ',' enumerator
	;

enumerator	/* identifiers must be flagged as ENUMERATION_CONSTANT */
	: enumeration_constant '=' constant_expression
	| enumeration_constant
	;

atomic_type_specifier
	: ATOMIC '(' type_name ')' { zig_error("", "Atomics are unsupported"); }
	;

type_qualifier
	: CONST { $$ = make_type_node(CONST); }
	| RESTRICT { zig_error("", "RESTRICT IS UNSUPPORTED."); }
	| VOLATILE { zig_error("", "VOLATILE IS UNSUPPORTED."); }
	| ATOMIC { zig_error("", "ATOMIC IS UNSUPPORTED."); }
	;

function_specifier
	: INLINE { zig_error("Try making the function normally!", "Inline functions are not supported."); }
	| NORETURN { zig_error("Try making a void function!", "NORETURN Functions are not supported."); }
	;

alignment_specifier
	: ALIGNAS '(' type_name ')' { zig_error("", "Alignas is not supported"); }
	| ALIGNAS '(' constant_expression ')' { zig_error("", "Alignas is not supported"); }
	;

declarator
	: pointer direct_declarator { $$ = make_idpointer_node($1, $2); }
	| direct_declarator
	;

direct_declarator
	: IDENTIFIER { $$ = make_identifier_node($1); } 
	| '(' declarator ')' { $$ = $2; }
	| direct_declarator '[' ']'
	| direct_declarator '[' '*' ']'
	| direct_declarator '[' STATIC type_qualifier_list assignment_expression ']'
	| direct_declarator '[' STATIC assignment_expression ']'
	| direct_declarator '[' type_qualifier_list '*' ']'
	| direct_declarator '[' type_qualifier_list STATIC assignment_expression ']'
	| direct_declarator '[' type_qualifier_list assignment_expression ']'
	| direct_declarator '[' type_qualifier_list ']'
	| direct_declarator '[' assignment_expression ']' {$$ = make_array_node($1,$3); }
	| direct_declarator '(' parameter_type_list ')' {$$ = make_name_parameter_node($1, $3); }
	| direct_declarator '(' ')' { $$ = make_name_parameter_node($1, NULL); }
	| direct_declarator '(' identifier_list ')'
	;

pointer
	: '*' type_qualifier_list pointer
	| '*' type_qualifier_list
	| '*' pointer { $$ = make_pointer_node($2); }
	| '*' { $$ = make_pointer_node(NULL); }
	;

type_qualifier_list
	: type_qualifier
	| type_qualifier_list type_qualifier
	;


parameter_type_list
	: parameter_list ',' ELLIPSIS
	| parameter_list
	;

parameter_list
	: parameter_declaration { $$ = append_parameter_list($1, NULL); }
	| parameter_list ',' parameter_declaration { $$ = append_parameter_list($3, $1); }
	;

parameter_declaration
	: declaration_specifiers declarator { 
        struct Node *assign = make_assignment_node($2, NULL, NULL);
        $$ = make_declaration_node($1, assign); 
    }
	| declaration_specifiers abstract_declarator
	| declaration_specifiers { 
        struct Node *assign = make_assignment_node($1, NULL, NULL);
        $$ = make_declaration_node($1, assign); 
    }
	;

identifier_list
	: IDENTIFIER
	| identifier_list ',' IDENTIFIER
	;

type_name
	: specifier_qualifier_list abstract_declarator
	| specifier_qualifier_list
	;

abstract_declarator
	: pointer direct_abstract_declarator
	| pointer
	| direct_abstract_declarator
	;

direct_abstract_declarator
	: '(' abstract_declarator ')'
	| '[' ']'
	| '[' '*' ']'
	| '[' STATIC type_qualifier_list assignment_expression ']'
	| '[' STATIC assignment_expression ']'
	| '[' type_qualifier_list STATIC assignment_expression ']'
	| '[' type_qualifier_list assignment_expression ']'
	| '[' type_qualifier_list ']'
	| '[' assignment_expression ']'
	| direct_abstract_declarator '[' ']'
	| direct_abstract_declarator '[' '*' ']'
	| direct_abstract_declarator '[' STATIC type_qualifier_list assignment_expression ']'
	| direct_abstract_declarator '[' STATIC assignment_expression ']'
	| direct_abstract_declarator '[' type_qualifier_list assignment_expression ']'
	| direct_abstract_declarator '[' type_qualifier_list STATIC assignment_expression ']'
	| direct_abstract_declarator '[' type_qualifier_list ']'
	| direct_abstract_declarator '[' assignment_expression ']'
	| '(' ')'
	| '(' parameter_type_list ')'
	| direct_abstract_declarator '(' ')'
	| direct_abstract_declarator '(' parameter_type_list ')'
	;

initializer
	: '{' initializer_list '}' { $$ = $2; }
	| '{' initializer_list ',' '}' { $$ = $2; }
	| assignment_expression
	;

initializer_list
    // : initializer                               { $$ = append_initializer_list($1, NULL); }
    // | initializer_list ',' initializer          { $$ = append_initializer_list($3, $1); }
    // | initializer_list ',' designation initializer { $$ = append_initializer_list($4, $1); }
    // ;
    : designation initializer                   { $$ = append_initializer_list($2, NULL); }
    | initializer                               { $$ = append_initializer_list($1, NULL); }
    | initializer_list ',' designation initializer { $$ = append_initializer_list($4, $1); }
    | initializer_list ',' initializer          { $$ = append_initializer_list($3, $1); }
    ;

designation
	: designator_list '='
	;

designator_list
	: designator
	| designator_list designator
	;

designator
	: '[' constant_expression ']'
	| '.' IDENTIFIER
	;

static_assert_declaration
	: STATIC_ASSERT '(' constant_expression ',' STRING_LITERAL ')' ';'
	;

statement
	: labeled_statement
	| compound_statement
	| expression_statement
	| selection_statement
	| iteration_statement
	| jump_statement
	;

labeled_statement
	: IDENTIFIER ':' statement
	| CASE constant_expression ':' statement
	| DEFAULT ':' statement
	;

compound_statement
	: '{' '}' 
	| '{'  block_item_list '}' { $$ = $2; }
	;

block_item_list
	: block_item { $$ = append_block_list($1, NULL); }
	| block_item_list block_item { $$ = append_block_list($2, $1); }
	;

block_item
	: declaration 
	| statement
	;

expression_statement
	: ';' { $$ = make_expr_stmt(NULL); }
	| expression ';' { $$ = make_expr_stmt($1); }
	;

selection_statement
	: IF '(' expression ')' statement ELSE statement { $$ = make_if_stmt($3, $5, $7); }
	| IF '(' expression ')' statement { $$ = make_if_stmt($3, $5, NULL); }
    | IF expression compound_statement ELSE compound_statement { $$ = make_if_stmt($2, $3, $5); }
    | IF expression compound_statement { $$ = make_if_stmt($2, $3, NULL); }
	| SWITCH '(' expression ')' statement
	| SWITCH expression compound_statement
	;

iteration_statement
	: WHILE '(' expression ')' statement { $$ = make_iteration_stmt($3, $5, NULL, NULL); }
	| WHILE expression compound_statement { $$ = make_iteration_stmt($2, $3, NULL, NULL); }
	| DO statement WHILE '(' expression ')' ';'
    | FOR expression_statement expression_statement compound_statement {$$ = make_iteration_stmt($3, $4, $2, NULL);}
    | FOR expression_statement expression_statement expression_statement compound_statement {$$ = make_iteration_stmt($3, $5, $2, $4);}
    | FOR declaration expression_statement expression compound_statement {$$ = make_iteration_stmt($3, $5, $2, $4);}
    | FOR declaration expression_statement compound_statement {$$ = make_iteration_stmt($3, $4, $2, NULL);}
	| FOR '(' expression_statement expression_statement ')' statement { $$ = make_iteration_stmt($4, $6, $3, NULL);}
	| FOR '(' expression_statement expression_statement expression ')' statement {$$ = make_iteration_stmt($4, $7, $3, $5);}
	| FOR '(' declaration expression_statement ')' statement { $$ = make_iteration_stmt($4, $6, $3, NULL);}
	| FOR '(' declaration expression_statement expression ')' statement {$$ = make_iteration_stmt($4, $7, $3, $5);}
	;

jump_statement
	: GOTO IDENTIFIER ';'
	| CONTINUE ';'          
	| BREAK ';'
	| RETURN ';' { $$ = make_return_node(NULL); }
	| RETURN expression ';' { $$ = make_return_node($2); }
	;

program
    : translation_unit { root = $$; }

translation_unit
	: external_declaration { 
        $$ = append_translation_unit($1, NULL);
    }
	| translation_unit external_declaration { $$ = append_translation_unit($2, $1); }
	;

external_declaration
	: function_definition
	| declaration
	;

function_definition
	: declaration_specifiers declarator declaration_list compound_statement
	| declaration_specifiers declarator compound_statement {$$ = make_function_node($1, $2, $3); }
	;

declaration_list
	: declaration
	| declaration_list declaration
	;

%%
