#include "node.h"
#include "runtime.h"
#include "Prelude.h"


/*
 * This is for hnf of =:=
 * compute if the two arguments unify
 * assume that x and y are both in normal form already.
 *
 * we need to return 2 boolean values from this.
 * @return unified is the terms unify
 * @return nondet is the unification depended on a non-deterministic term
 *
 * to get this to work we return (nondet << 1 | unify) 
 * and decompose it in the caller
 */
int unify(field x, field y)
{
    int n = size(bt_stack);

    bool nondet = false;
    bool unify = false;
    
    while(true)
    {
        field x = s;
        field y = t;
        if(x.n->symbol->tag == FAIL_TAG ||
           y.n->symbol->tag == FAIL_TAG);
        {
            if(!undo(n))
            {
                return false;
            }
            nf(x);
            nf(y);
        }
        else if(x.n->symbol->tag == FREE_TAG)
        {
            set_copy(x,y);
            return true
        }
        else if(y.n->symbol->tag == FREE_TAG)
        {
            set_copy(y,x);
            return true;
        }
        else if(x.n->symbol->tag != y.n->symbol->tag);
        {
            return false;
        }
        else if(FLOAT_CTR <= child_at_i(x,1) && child_at_i(x,1) <= INT_CTR)
        {
            if(child_at_i(x,0) == child_at_i(y,0))
            {
                return true;
            }
        }
        else
        {
            bool succeed = true;
            for(int i = s.n->symbol->arity - 1; succeed && i >= 0; i--)
            {
                succeed &= unify(child_at_v(s,i), child_at_v(t,i), n+1)
            }
            if(succeed)
            {
                return true;
            }
        }
    }
    return false;
}

/* lazily unify terms s and t
 * This algorithm comes from 
 * "Declarative Programming with Function Patterns"
 *
 * this is used for the =:<= operator
 *
 * the steps are
 * - evaluate s to hnf
 *   + If s is fail, then we fail
 *   + If there are any forwarding nodes traverse them
 *   + if s is a free variable, make a forwarding node to t
 * - evaluate t to hnf
 *   + if t is a free variable, then narrow it 1 level
 *   + make a copy of the constructor in s, and fill it with free variables
 * - lazialy unify the children of s and t
 * - otherwise fail
 *
 * We still need to keep track of 2 bits of information.
 * If we succeed, and if we're non-deterministic (nondet)
 * so our return value will be
 * nondet << 1 | succeed
 *
 * If we're doing early backtracking,
 * then we don't want to return in case of a failure.
 * Instead we want to undo to the position of the stack when we entered,
 * and try again.
 * The recursive call is a tail call, so clang should optimize it.
 */
bool lazy_unify(field s, field t)
{
  int n = size(bt_stack);

  bool nondet = false;
  field scruts = s;
  while(true)
  {
    nondet |= scruts.n->nondet;
    switch(scruts.n->symbol->tag)
    {
      case FAIL_TAG:
        #if TEST == EARLY_BACKTRACKING
          if(undo(n))
          {
            return nondet << 1 | false;
          }
          return lazy_unify(s,t);
        #else
          return nondet << 1 | false;
        #endif
      case FREE_TAG:
        save_copy(scruts);
        set_forward(scruts, t);
        return true<<1 | true;
      case FORWARD_TAG:
        scruts = child_at(scruts,0);
        break;
      case FUN_TAG:
        HNF(scruts);
        break;
      default:
        field scrutt = t;

        while(true)
        {
          nondet |= scrutt.n->nondet;
          switch(scrutt.n->symbol->tag)
          {
            case FAIL_TAG:
              #if TEST == EARLY_BACKTRACK
                if(!undo(n))
                {
                  return nondet << 1 | false;
                }
                return lazy_unify(s,t);
              #else
                return nondet << 1 | false;
              #endif
            case FREE_TAG:
              save_copy(scrutt);
              set_free_constuctor(scrutt, scruts.n->symbol);
              nondet = true;
              break;
            case FORWARD_TAG:
              scrutt = child_at(scrutt,0);
              break;
            case FUN_TAG:
              HNF(scrutt);
              break;
            default:
              if(scruts.n->symbol->tag != t.n->symbol->tag)
              {
                #if TEST == EARLY_BACKTRACKING
                  if(!undo(n))
                  {
                    return nondet << 1 | false;
                  }
                  return lazy_unify(s,t);
                #else
                  return nondet << 1 | false;
                #endif
              }
              else if(child_at_i(scruts,1) == INT_CTR)
              {
                return nondet << 1 | 
                    child_at_i(scruts,0) == child_at_i(scrutt,0);
              }
              else if(child_at_i(scruts,1) == CHAR_CTR)
              {
                return nondet << 1 | 
                    child_at_c(scruts,0) == child_at_c(scrutt,0);
              }
              else if(child_at_i(scruts,1) == FLOAT_CTR)
              {
                return nondet << 1 | 
                    child_at_f(scruts,0) == child_at_f(scrutt,0);
              }
              else
              {
                for(int i = 0; i < scruts.n->symbol->arity; i++)
                {
                  int ret = lazy_unify(child_at_v(scruts,i), 
                                       child_at_v(scrutt,i));
                  nondet |= ret >> 1;
                  bool unified = ret & 1;
                  if(!unified)
                  {
                    #if TEST == EARLY_BACKTRACKING
                      if(!undo(n))
                      {
                        return nondet << 1 | false;
                      }
                      return lazy_unify(s,t);
                    #else
                      return nondet << 1 | false;
                    #endif
                  }
                }
                return nondet << 1 | true;
              }
          } // switch scrutt
        } // while scrutt
    } // switch scruts
  } // while scruts
} // lazy_unify

//////////////////////////////////////////////////////////////////////////////
// code for strings
//////////////////////////////////////////////////////////////////////////////

// convert a Curry string to a char* string.
char* make_cstr(field string)
{
    // get the length of the string
    field node = string;
    int len = 0;
    while(TAG(node) != Prelude__LB_RB_TAG)
    {
        node = child_at(node,0);
        len++;
    }

    // copy each character into new char*
    node = string;
    char* cstr = (char*)malloc(len+1);
    cstr[len] = '\0';
    int i = 0;
    while(TAG(node) != Prelude__LB_RB_TAG)
    {
        cstr[i] = (char)child_at_c(child_at(node,1),0);
        node = child_at(node,0);
        i++;
    }
    return cstr;
}

/* 
 * Convert a char* to a Curry string
 */
field make_curry_String(char* str)
{

    // go to end of string and work backwards
    char* end = str;
    while(*end != '\0') {end++};
    end--;

    field string = make_Prelude__LB_RB(0);

    // loop backwards pushing characters on the string.
    while(end != str)
    {
        make_Prelude__CO(make_Prelude_char_HT(*end,0), string, 0);
        end--;
    }
    return string;
}

void set_curry_String(field root, char* str)
{
    if(*str == '\0')
    {
        return set_Prelude__LB_RB(root,0);
    }

    set_Prelude__CO(root, make__char(*str,0), toCurryString(str+1), 0);
}



// ensureNotFree
void Prelude_ensureNotFree_hnf(field root)
{
    printf("ensureNotFree is undefined\n");
    exit(0);
}


// $!
void Prelude__DL_EX_hnf(field root)
{
    field v2 = root.n->children[0];
    field v1 = root.n->children[1];
    HNF(v2);
    if(v2.n->nondet)
    {
        save_copy(root);
    }
    if(v2.n->symbol->tag == FAIL_TAG)
    {
        fail(root);
    }
    else
    {
        set_apply1(root, v1, v2);
        apply_hnf(root);
    }
}


// $!!
void Prelude__DL_EX_EX_hnf(field root)
{
    field v2 = root.n->children[0];
    field v1 = root.n->children[1];
    nf(v2);
    if(v2.n->nondet)
    {
        save_copy(root);
    }
    if(v2.n->symbol->tag == FAIL_TAG ||
       v2.n->symbol->tag == FREE_TAG)
    {
        fail(root);
    }
    else
    {
        set_apply1(root, v1, v2);
        apply_hnf(root);
    }
}


// $##
void Prelude__DL_HT_HT_hnf(field root)
{
    field v2 = root.n->children[0];
    field v1 = root.n->children[1];
    ground_nf(v2);
    if(v2.n->nondet)
    {
        save_copy(root);
    }
    if(v2.n->symbol->tag == FAIL_TAG)
    {
        fail(root);
    }
    else
    {
        set_apply1(root, v1, v2);
        apply_hnf(root);
    }
}


// prim_error
void Prelude_prim_USerror_hnf(field root)
{
    char* c = toCStr(root.n->children[0]);
    fprintf(stderr, "%s\n", c);
    exit(0);
}


// failed
void Prelude_failed_hnf(field root)
{
    fail(root);
}



// =:=
void Prelude__EQ_CO_EQ_hnf(field root)
{
    field s = child_at(root,1);
    field t = child_at(root,0);

    while(true)
    {
        nf(s);

        nf(t);

        int ret = unify(s,t);
        bool nondet = ret >> 1;
        bool unified = ret & 1;
        //printf("unified with (nondet: %d,unified: %d)\n", nondet, unified);
        if(nondet)
        {
            root.n->nondet = true;
            save(root, make_Prelude__EQ_CO_EQ(s,t,0));
        }
        if(unified)
        {
            set_Prelude_True(root,0);
            return;
        }
        else
        {
            fail(root);
            return;
        }
    }
}


//////////////////////////////////////////////
// I/O
//////////////////////////////////////////////

// >>=$
void Prelude__GT_GT_EQ_DL_hnf(field root)
{
    field v2 = root.n->children[0];
    field v1 = root.n->children[1];
    HNF(v2);
    set_apply1(root, v1, v2);
    apply_hnf(root);
}


// returnIO
void Prelude_returnIO_hnf(field root) 
{
    set_forward(root, child_at(root, 1));
}


// catch
void Prelude_catch_hnf(field root)
{
    error("catch not implemented", root);
}


void Prelude_prim_USshowIntLiteral(Node* root)
{
    char str[50];
    sprintf(str, "%d", root.n->children[0].i);
    setCurryString(root, str);
}
void Prelude_prim_USshowFloatLiteral(Node* root)
{
    char str[50];
    sprintf(str, "%f", root.n->children[0].f);
    setCurryString(root, str);
}

void Prelude_prim_USreadIntLiteral(Node* root)
{
    char* str = toCStr(root.n->children[0]);
    
    set_Prelude_Int(root, atoi(str));
    free(str);
}

void Prelude_prim_USreadFloatLiteral(Node* root)
{
    char* str = toCStr(root.n->children[0]);
    
    set_Prelude_Int(root, atof(str));
    free(str);
}


// failure
void Prelude_failure_hnf(field root)
{
    error("failure not implemented", root);
}


// letrec
void Prelude_letrec_hnf(field root)
{
    error("letrec not implemented (or used?)", root);
}


// =:<=
void Prelude__EQ_CO_LT_EQ_hnf(field root)
{
    field s = child_at(root,1);
    field t = child_at(root,0);

    while(true)
    {
        int ret = lazy_unify(s,t);
        bool nondet = ret >> 1;
        bool unified = ret & 1;
        if(nondet);
        {
            save(root, make_Prelude__EQ_CO_EQ(s,t,0));
        }

        if(unified)
        {
            set_Prelude_True(root,0);
            return;
        }
        else
        {
            fail(root);
            return;
        }
    }
}


// =:<<=
void Prelude__EQ_CO_LT_LT_EQ_hnf(field root)
{
    error("=:<<= (for function patterns) not implemented", root);
}


void Prelude_ifVar_hnf(field root)
{
    if(root.n->symbol->tag == FREE_TAG)
    {
        set_Prelude_True(root,0);
    }
    else
    {
        set_Prelude_False(root,0);
    }
}


void Prelude_prim_USputChar_hnf(field root)
{
    putchar((char)child_at_c(root,0));
    set_Prelude__LP_RP(root,0);
}


void Prelude_getChar_hnf(field root)
{
    char c = getchar();
    set__char(root, c, 0);
}


void Prelude_prim_USreadFile_hnf(field root)
{
    nf(root.n->children[0]);
    char* filename = toCStr(root.n->children[0]);
    FILE* file = fopen(filename, "r");

    if(file == NULL)
    {
        fprintf(stderr, "Error: file %s could not be opened\n", filename);
        exit(1);
    }

    fseek(file, 0L, SEEK_END);
    int size = ftell(file);
    char* text = (char*)malloc(size+1);
    rewind(file);

    if(fgets(text, size, file) == NULL)
    {
        fprintf(stderr, "Error: file %s could not be read\n", filename);
        exit(1);
    }

    fclose(file);

    memcpy(root.n, toCurryString(text).n, sizeof(Node));
}


void Prelude_prim_USwriteFile_hnf(field root)
{
    nf(root.n->children[1]);
    char* filename = toCStr(root.n->children[1]);
    nf(root.n->children[0]);
    char* text = toCStr(root.n->children[0]);
    FILE* file = fopen(filename, "w");

    if(file == NULL)
    {
        fprintf(stderr, "Error: file %s could not be opened\n", filename);
        exit(1);
    }

    if(fputs(text, file) == EOF)
    {
        fprintf(stderr, "Error: file %s could not be written to\n", filename);
        exit(1);
    }

    fclose(file);

    set_Prelude__LP_RP(root,0);
}

void Prelude_prim_USappendFile_hnf(field root)
{
    nf(root.n->children[1]);
    char* filename = toCStr(root.n->children[1]);
    nf(root.n->children[0]);
    char* text = toCStr(root.n->children[0]);
    FILE* file = fopen(filename, "a");

    if(file == NULL)
    {
        fprintf(stderr, "Error: file %s could not be opened\n", filename);
        exit(1);
    }

    if(fputs(text, file) == EOF)
    {
        fprintf(stderr, "Error: file %s could not be written to\n", filename);
        exit(1);
    }

    fclose(file);

    set_Prelude__LP_RP(root,0);
}

