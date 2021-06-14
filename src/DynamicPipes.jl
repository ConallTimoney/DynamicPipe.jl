module DynamicPipes

export @>>
export @> 

# function to impute the first part of @>> if it contains underscores 
# this allows you to use pipes in pipes @>> 2 |> sum([3, @>> _ |> sqrt(_)]) == sum([3, sqrt(2)])
function replace_first_part_of_pipe(pipe::Expr, new_arg::Symbol)
    pipe_subsection = pipe.args[3]
    # get the first element of the pipe 
    while pipe_subsection isa Expr 
        if pipe_subsection.head == :call && pipe_subsection.args[1] ∈ [:|>, :.|>]
            global previous_pipe_subsection = pipe_subsection
            pipe_subsection = pipe_subsection.args[2]  
        else
            break
        end  
    end
    contains_underscore = false
    # rewrite the the first part of the pipe 
    if pipe_subsection isa Expr
        new_code, contains_underscore = rewrite_function_internal(pipe_subsection,
                                                                  new_arg,
                                                                  impute_as_first_arg = false)
        pipe_subsection.args = new_code.args
    elseif pipe_subsection == :_
        contains_underscore = true
        previous_pipe_subsection.args[2] = new_arg
    end
    return pipe, contains_underscore
end

# function to convert the expressions between the pipes |> ... |>
# replace underscores with the new argument and possibel impute the first arguemnt 
# if there is no underscore 
function rewrite_function_internal(code::Expr, new_arg; impute_as_first_arg = true)
    excluded_macros = (Symbol("@>>"), Symbol("@>"))

    contains_underscore = false
        
    loop_start_point = code.head ∈ [:call, :kw] ? min(2, length(code.args)) :
                       code.head == :macrocall ? min(3, length(code.args)) : 
                       1

    # loop through replacing underscores with the new argument         
    for (location, arg) in [enumerate(code.args)...][loop_start_point:end]
        if arg == :_
            code.args[location] =  new_arg
            contains_underscore = true 
        elseif arg isa Expr
            if arg.head ≠ :macrocall || (arg.head == :macrocall && arg.args[1] ∉ excluded_macros)
                code.args[location], had_underscore = rewrite_function_internal(arg, new_arg, impute_as_first_arg = false)
                contains_underscore = had_underscore || contains_underscore
            elseif arg.head == :macrocall && arg.args[1] == Symbol("@>>")
                code.args[location], contains_underscore = replace_first_part_of_pipe(arg, new_arg)
            end
        end
    end
    
    # if does not conatin and we are imputeing the first arguemnt
    if impute_as_first_arg && !contains_underscore
        if  code.head == :call
            if length(code.args) > 1 
                code.args = [code.args[1], new_arg, code.args[2:end]...]
            else 
                code.args = [code.args[1], new_arg]
            end
        elseif code.head == :macrocall 
            if code.args[1] ∉ excluded_macros
                if length(code.args) > 2
                    code.args = [code.args[1], code.args[2], new_arg, code.args[3:end]...]
                else
                    code.args = [code.args[1], code.args[2], new_arg]
                end   
            end
        #vectorised function handling 
        elseif code.head == :.
            if !(code.args[2] isa QuoteNode)
                code.args[2].args = [new_arg, code.args[2].args...]
            end
        end
    end
    
    return code, contains_underscore
end 


function rewrite_function_internal(code::Symbol, new_arg) 
    return :($code($new_arg)), nothing
end

# function to recursivly convert the internal parts of the pipe, |> ... |>
function form_pipe(pipe_func, first_part, second_part, new_arg; evaluate_pipe = false)
    # if we have not yet got to the start of the pipe  
    if first_part isa Expr
        if first_part.head == :call 
            if first_part.args[1] ∈ [:|>, :.|>]
                return form_pipe(first_part.args[1],
                                first_part.args[2],
                                :($new_arg -> $(Expr(:call, pipe_func, rewrite_function_internal(first_part.args[end], new_arg)[1], second_part))),
                                new_arg,
                                evaluate_pipe = evaluate_pipe)
            end
        end
    end
    # we are at the start of the pipe 
    if !evaluate_pipe 
        return :($new_arg -> $(Expr(:call, pipe_func, rewrite_function_internal(first_part, new_arg)[1], second_part)))
    else
        return Expr(:call, pipe_func, first_part, second_part)
    end    
end 

# function that writes the supplied expression 
function rewrite_code(code::Expr; evaluate_pipe = false)
    new_arg = gensym(:_)
    if code.head == :call 
        if code.args[1] ∈ [:|>, :.|>]
            return form_pipe(code.args[1],
                            code.args[2], 
                            :($new_arg -> $(rewrite_function_internal(code.args[end], new_arg)[1])),
                            new_arg,
                            evaluate_pipe = evaluate_pipe)
        end
    end 
    if evaluate_pipe
        error("If not acting on block @>> must contain at least one pipe, |>.")
    else 
        return :($new_arg ->  $(rewrite_function_internal(code, new_arg)[1]))
    end
end


function rewrite_code(code::Symbol)
    new_arg = gensym(:_)
    return :($new_arg -> $(rewrite_function_internal(code, new_arg)[1]))
end


# convert block of code to a function 
function rewrite_block(code; evaluate_pipe = false)
    new_arg = gensym(:_)
    functions = code.args[map((!(x -> isa(x, LineNumberNode))), code.args)]
    
    # transform into a pipe so we can use form_pipe
    if length(functions) > 1
        pipe = Expr(:call, :|>, functions[1], functions[2])
        if length(functions) > 2
            for func in functions[3:end]
                pipe = Expr(:call, :|>, pipe, func)
            end
        end
        return form_pipe(pipe.args[1],
                        pipe.args[2], 
                        :($new_arg -> $(rewrite_function_internal(pipe.args[end], new_arg)[1])),
                        new_arg,
                        evaluate_pipe = evaluate_pipe)
    else
        if evaluate_pipe
            error("If @>> is acting on a block then the block must contain multiple lines.")
        else 
            return :($new_arg ->  $(rewrite_function_internal(functions[1], new_arg)[1]))
        end
    end
end


"""
    @>(code)
    
Rewrites code to create an anonymous function that takes one argument. Designed to pipe one object 
through multiple functions. 

The functions are created using the following rules:
1. Underscores are treated as the function argument. `@> sum(_)` is equivalent to `x -> sum(x)`
2. If the is no underscore in the expression then then the the first argument is imputed,
`@> +(3)` is equivalent to `x -> +(x, 3)`
3. If expression is symbol then it is treated as function so `@> print` is interpreted as 
`x -> print(x)`
4. The above 2 rules are applied to expressions separate by the pipe operator, `|>`. Hence 
`@> [_, 1, 2] |> sum()` is equivalent to `x -> [x, 1, 2] |> x -> sum(x)`
5. These rules also apply to macros, with the exception of @> and @>>. Hence `@> @show`  

The macro can also be used in itself. Although will often require the use of brackets to get the 
desired effect. 

Example: 
```julia-repl
julia> 1 |>
           @>  [_ |> @>(_ + 2), 1, 1] |>
               sum
5

```
"""
macro >(code::Symbol)
    return :($(esc(rewrite_code(code))))
end

"""
    @>(code)
    
Rewrites code to create an anonymous function that takes one argument. Designed to pipe one object 
through multiple functions. 

The functions are created using the following rules:
1. Underscores are treated as the function argument. `@> sum(_)` is equivalent to `x -> sum(x)`
2. If the is no underscore in the expression then then the the first argument is imputed,
`@> +(3)` is equivalent to `x -> +(x, 3)`
3. If expression is symbol then it is treated as function so `@> print` is interpreted as 
`x -> print(x)`
4. The above 2 rules are applied to expressions separate by the pipe operator, `|>`. Hence 
`@> [_, 1, 2] |> sum()` is equivalent to `x -> [x, 1, 2] |> x -> sum(x)`
5. These rules also apply to macros, with the exception of @> and @>>. Hence `@> @show`  

The macro can also be used in itself. Although will often require the use of brackets to get the 
desired effect. 

Example: 
```julia-repl
julia> 1 |>
           @>  [_ |> @>(_ + 2), 1, 1] |>
               sum
5

```
"""
macro >(code::Expr)
    if code.head == :block
        return :($(esc(rewrite_block(code))))
    else
        return :($(esc(rewrite_code(code))))
    end
end




"""
    @>(code)
    
Rewrites code to create an anonymous function that takes one argument. Designed to pipe one object 
through multiple functions. 

The functions are created using the following rules:
1. Underscores are treated as the function argument. `@> sum(_)` is equivalent to `x -> sum(x)`
2. If the is no underscore in the expression then then the the first argument is imputed,
`@> +(3)` is equivalent to `x -> +(x, 3)`
3. If expression is symbol then it is treated as function so `@> print` is interpreted as 
`x -> print(x)`
4. The above 2 rules are applied to expressions separate by the pipe operator, `|>`. Hence 
`@> [_, 1, 2] |> sum()` is equivalent to `x -> [x, 1, 2] |> x -> sum(x)`
5. These rules also apply to macros, with the exception of @> and @>>. Hence `@> @show`  

The macro can also be used in itself. Although will often require the use of brackets to get the 
desired effect. 

Example: 
```julia-repl
julia> 1 |>
           @>  [_ |> @>(_ + 2), 1, 1] |>
               sum
5

```
"""
macro >(code)
    error("@> can only act on Symbols and Expresions not $(typeof(code))")
end




"""
    @>>(code)
    
Rewrites code using the same rewriting rules as @> only the first element of the pipe is not 
rewritten and is instead passed through the pipe. 

The functions are created using the following rules:
1. Underscores are treated as the function argument. `@>> [1,2,3] |> sum(_)` is equivalent to 
`[1,2,3] |> x -> sum(x)`
2. If the is no underscore in the expression then then the the first argument is imputed,
`@>> [1,2,3] |> .+(3)` is equivalent to `[1,2,3] |> x -> .+(x, 3)`
3. If expression is symbol then it is treated as function so `@> "hello world" |> print` is interpreted as 
`"hello world" |> x -> print(x)`
4. The above 2 rules are applied to expressions separated by the pipe operator, `|>`. Hence 
`@>> 1 |> [_, 1, 2] |> sum()` is equivalent to `1 |> x -> [x, 1, 2] |> x -> sum(x)`
5. These rules also applied to macros, with the exception of @> and @>>. Hence `@>> "hello world" |> @show` 
is equivalent to `"hello world" |> @show(_)` 
6. The macro can also be used in itself. If the @>> appears within itself or @> and _ is in the first 
section of the pipe then it comes from the surrounding context. See the example below.  

Example: 
```julia-repl
julia> @>> 1 |>
            [(@>> _ |> +(2)), 1, 1] |>
            sum
5

```
"""
macro >>(code::Expr)
    if code.head == :block
        return :($(esc(rewrite_block(code, evaluate_pipe = true))))
    else 
        return :($(esc(rewrite_code(code, evaluate_pipe = true))))
    end
end


"""
    @>>(code)
    
Rewrites code using the same rewriting rules as @> only the first element of the pipe is not 
rewritten and is instead passed through the pipe. 

The functions are created using the following rules:
1. Underscores are treated as the function argument. `@>> [1,2,3] |> sum(_)` is equivalent to 
`[1,2,3] |> x -> sum(x)`
2. If the is no underscore in the expression then then the the first argument is imputed,
`@>> [1,2,3] |> .+(3)` is equivalent to `[1,2,3] |> x -> .+(x, 3)`
3. If expression is symbol then it is treated as function so `@> "hello world" |> print` is interpreted as 
`"hello world" |> x -> print(x)`
4. The above 2 rules are applied to expressions separated by the pipe operator, `|>`. Hence 
`@>> 1 |> [_, 1, 2] |> sum()` is equivalent to `1 |> x -> [x, 1, 2] |> x -> sum(x)`
5. These rules also applied to macros, with the exception of @> and @>>. Hence `@>> "hello world" |> @show` 
is equivalent to `"hello world" |> @show(_)` 
6. The macro can also be used in itself. If the @>> appears within itself or @> and _ is in the first 
section of the pipe then it comes from the surrounding context. See the example below.  

Example: 
```julia-repl
julia> @>> 1 |>
            [(@>> _ |> +(2)), 1, 1] |>
            sum
5

```
"""
macro >>(code)
    error("@>> can only act on expressions containing a pipe, |>, not $(typeof(code)).")
end


macro >>(first_arg, pipe::Expr)
    if pipe.head == :block
        pipe.args = [first_arg, pipe.args...]
        return :(@>> $pipe)
    end
    error("When @>> is acting on 2 arguments the second argument must be a \"begin ... end\" block expression.")
end

macro >>(first_arg, second_arg)
    error("When @>> is acting on 2 arguments the second argument must be a \"begin ... end\" block expression not $(typeof(second_arg)). ")
end

macro >>(code::Expr)
    if code.head == :block
        return :($(esc(rewrite_block(code, evaluate_pipe = true))))
    else 
        return :($(esc(rewrite_code(code, evaluate_pipe = true))))
    end
end

end #module