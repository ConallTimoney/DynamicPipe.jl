module DynamicPipe

export @>>
export @> 

pipe_symbols = [:|>, :.|>]

function get_first_part_of_pipe(pipe)
    global pipe_subsection = pipe
    while pipe_subsection isa Expr 
        if pipe_subsection.head == :call && pipe_subsection.args[1] ∈ pipe_symbols
            # previous_pipe_subsection for when the first part is just _ as we can't re write this in-place 
            global previous_pipe_subsection = pipe_subsection
            global pipe_subsection = pipe_subsection.args[2]
        else 
            break
    end end
    return pipe_subsection, previous_pipe_subsection
end

# function to impute the first part of @>> if it contains underscores 
# this allows you to use pipes in pipes @>> 2 |> sum([3, @>> _ |> sqrt(_)]) == sum([3, sqrt(2)])
function rewrite_first_part_of_pipe_macro(pipe::Expr, new_arg::Symbol)
    pipe_subsection = pipe.args[3]
    # if of the form @>> arg begin ... end 
    if (pipe.args |> length) == 4 && pipe.args[end].head == :block
        pipe.args[3], contains_underscore =create_internal_function_code(pipe_subsection
                                                                      ,new_arg
                                                                      ,impute_as_first_arg = false)
        return pipe, contains_underscore
    else  
        # if of the form @>> block .. end
        if pipe_subsection.head == :block
            pipe_subsection = pipe_subsection.args[2]
            pipe.args[3].args[2], contains_underscore = create_internal_function_code(pipe_subsection
                                                                                      ,new_arg
                                                                                      ,impute_as_first_arg = false)
            return pipe, contains_underscore
        else
            pipe_subsection, previous_pipe_subsection = get_first_part_of_pipe(pipe_subsection)
            contains_underscore = false
            # rewrite the the first part of the pipe 
            if pipe_subsection isa Expr
                new_code, contains_underscore = create_internal_function_code(pipe_subsection,
                                                                              new_arg,
                                                                              impute_as_first_arg = false)
                # may not need to do this now we are not copying the code in rewrite_function_internal
                pipe_subsection.args = new_code.args
            elseif pipe_subsection == :_
                contains_underscore = true
                previous_pipe_subsection.args[2] = new_arg
            end
            return pipe, contains_underscore
        end
    end
end

# function to convert the expressions between the pipes |> ... |>
# replace underscores with the new argument and possible impute the first argument 
# if there is no underscore  
function create_internal_function_code(code::Expr
                                      ,new_arg::Symbol
                                      ;impute_as_first_arg = true)
    excluded_macros = (Symbol("@>>"), Symbol("@>"))

    contains_underscore = false
        
    loop_start_point = code.head ∈ [:call, :kw] ? min(2, length(code.args)) :
                       code.head == :macrocall ? min(3, length(code.args)) : 
                       1
                       
    new_code = copy(code)
    if new_code.head == :macrocall
        if new_code.args[1] ∈ excluded_macros
            if new_code.args[1] == Symbol("@>>")
                return  rewrite_first_part_of_pipe_macro(new_code, new_arg)
            else # it is a @> macro
                return new_code, false
            end
        end
    end
    # loop through replacing underscores with the new argument         
    for (location, arg) in [enumerate(new_code.args)...][loop_start_point:end]
        if arg == :_
            new_code.args[location] =  new_arg
            contains_underscore = true 
        elseif arg isa Expr
            if arg.head == :call && arg.args[1] ∈ pipe_symbols
                # new_arg = gensym()
                if arg.args[end] isa Expr
                    if arg.args[end].head == :macrocall
                        if arg.args[end].args[1] == Symbol("@>") # we don't want to rewrite this 
                            arg.args[2], had_underscore = create_internal_function_code(arg.args[2], new_arg, impute_as_first_arg = false)
                            contains_underscore = contains_underscore || had_underscore
                            continue
                end end end 
                
                new_code.args[location], had_underscore = form_pipe(arg.args[1]
                                                                ,arg.args[2]
                                                                ,:($new_arg -> $(create_internal_function_code(arg.args[end], new_arg)[1]))
                                                                ,new_arg
                                                                ,rewrite_first_part = true
                                                                ,outer_pipe_arg = new_arg)
                contains_underscore = contains_underscore || had_underscore
            
            
            elseif arg.head ≠ :macrocall || (arg.head == :macrocall && arg.args[1] ∉ excluded_macros)
                new_code.args[location], had_underscore = create_internal_function_code(arg, new_arg, impute_as_first_arg = false)
                contains_underscore = had_underscore || contains_underscore
            elseif arg.head == :macrocall && arg.args[1] == Symbol("@>>")
                new_code.args[location], had_underscore = rewrite_first_part_of_pipe_macro(arg, new_arg)
                contains_underscore = contains_underscore || had_underscore
            end
        end
    end

    # if does not contain and we are imputing the first argument
    if impute_as_first_arg && !contains_underscore
        if  new_code.head == :call
            if length(new_code.args) > 1 
                new_code.args = [new_code.args[1], new_arg, new_code.args[2:end]...]
            else 
                new_code.args = [new_code.args[1], new_arg]
            end
        elseif new_code.head == :macrocall 
            if new_code.args[1] ∉ excluded_macros
                if length(new_code.args) > 2
                    new_code.args = [new_code.args[1], new_code.args[2], new_arg, new_code.args[3:end]...]
                else
                    new_code.args = [new_code.args[1], new_code.args[2], new_arg]
                end   
            end
        #vectorised function handling 
        elseif new_code.head == :.
            if !(new_code.args[2] isa QuoteNode)
                new_code.args[2].args = [new_arg, new_code.args[2].args...]
            end
        end
    end
    return new_code, contains_underscore
end 



function create_internal_function_code(code::Symbol, new_arg::Symbol; impute_as_first_arg = true)
    if code == :_ 
        return new_arg, true
    elseif impute_as_first_arg 
        return :($code($new_arg)), false
    else 
        return code, false
    end
end

function create_internal_function_code(code, new_arg::Symbol; impute_as_first_arg = true)
    return code, false
end

function create_anonymous_function(code
                                   ,new_arg::Symbol
                                   ;impute_as_first_arg = true)

    new_internal_code, had_underscore = create_internal_function_code(code, new_arg, impute_as_first_arg = impute_as_first_arg)
    return :($new_arg -> $new_internal_code), had_underscore
end

function create_anonymous_function(code::Expr
                                   ,new_arg::Symbol
                                   ;impute_as_first_arg = true)
    # don't do anything if @> macrocall 
    if code.head == :macrocall
        if code.args[1]  == Symbol("@>")
            return code, false
        end    
    end    
    new_internal_code, had_underscore = create_internal_function_code(code, new_arg, impute_as_first_arg = impute_as_first_arg)
    return :($new_arg -> $new_internal_code), had_underscore
end


# function to recursivly convert the internal parts of the pipe, |> ... |>
function form_pipe(pipe_func, first_part, second_part, new_arg; rewrite_first_part = false, outer_pipe_arg = nothing)
    # if we have not yet got to the start of the pipe  
    if first_part isa Expr
        if first_part.head == :call 
            if first_part.args[1] ∈ pipe_symbols
                return form_pipe(first_part.args[1],
                                first_part.args[2],
                                #Expr(:call, pipe_func, create_anonymous_function(first_part.args[end], new_arg)[1], second_part),
                                :($new_arg -> $(Expr(:call, pipe_func, create_internal_function_code(first_part.args[end], new_arg)[1], second_part))),
                                new_arg,
                                rewrite_first_part = rewrite_first_part,
                                outer_pipe_arg = outer_pipe_arg)
            end
        end
    end
    # we are at the start of the pipe 
    if rewrite_first_part 
         if outer_pipe_arg |> isnothing 
            #Expr(:call, pipe_func, create_anonymous_function(first_part, new_arg)[1], second_part)
            return :($new_arg -> $(Expr(:call, pipe_func, create_internal_function_code(first_part, new_arg)[1], second_part)))
         else 
            # we are in forming a pipe in a pipe so we need to know if there is an underscore in the first part
            new_first_part, has_underscore = create_internal_function_code(first_part, outer_pipe_arg, impute_as_first_arg = false)
            return Expr(:call, pipe_func, new_first_part, second_part), has_underscore
         end
    else
        return Expr(:call, pipe_func, first_part, second_part)
    end    
end 

# function that writes the supplied expression 
function rewrite_code(code::Expr; rewrite_first_part = false)
    new_arg = gensym()
    if code.head == :call 
        if code.args[1] ∈ pipe_symbols
            return form_pipe(code.args[1],
                            code.args[2], 
                            #create_anonymous_function(code.args[end], new_arg)[1],
                            :($new_arg -> $(create_internal_function_code(code.args[end], new_arg)[1])),
                            new_arg,
                            rewrite_first_part = rewrite_first_part,
                            outer_pipe_arg = nothing)
        end
    end 
    if !rewrite_first_part
        error("If not acting on block @>> must contain at least one pipe, |>.")
    else 
        return create_anonymous_function(code, new_arg)[1]
        # return :($new_arg ->  $create_internal_function_code(code, new_arg)[1]))
    end
end


function rewrite_code(code::Symbol)
    new_arg = gensym()
    return create_anonymous_function(code, new_arg)[1]
    # return :($new_arg -> $create_internal_function_code(code, new_arg)[1]))
end


# convert block of code to a function 
function rewrite_block(code; rewrite_first_part = false)
    new_arg = gensym()
    # just get the functions remove the line line nodes 
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
                        :($new_arg -> $(create_internal_function_code(pipe.args[end], new_arg)[1])),
                        #create_anonymous_function(pipe.args[end], new_arg)[1],
                        new_arg,
                        rewrite_first_part = rewrite_first_part)
    else
        if !rewrite_first_part
            error("If @>> is acting on a block then the block must contain multiple lines.")
        else 
            return create_anonymous_function(functions[1], new_arg)[1]
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
5. These rules also apply to macros, with the exception of @> and @>>.`  
6. The input can also be a `begin end block`. A separate function is created for each line in the 
block with result of previous function passed into the next using the re-writing rules. 
7. If there is a sequence of pipe characters within a sequence of pipe characters then a new pipe is 
is created if the first part of the pipe does not contain an underscore so @> [_, 2, sqrt(36) |> _/2] 
is equivalent to x -> [x, 3, sqrt(36) |> y -> y/2]. 

The macro can also be used in itself. Although will often require the use of brackets to get the 
desired effect. 

Examples: 
```julia-repl
julia> 1 |>
           @>  [_ |> @>(_ + 2), 1, 1] |>
               sum
5
```

```julia-repl
julia> 1 |>
           @>  begin
                [1, 1, _ |> @> +(1, 2)] 
                sum
            end
6
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
5. These rules also apply to macros, with the exception of @> and @>>.`  
6. The input can also be a `begin end block`. A separate function is created for each line in the 
block with result of previous function passed into the next using the re-writing rules. 
7. If there is a sequence of pipe characters within a sequence of pipe characters then a new pipe is 
is created if the first part of the pipe does not contain an underscore so @> [_, 2, sqrt(36) |> _/2] 
is equivalent to x -> [x, 3, sqrt(36) |> y -> y/2]. 

The macro can also be used in itself. Although will often require the use of brackets to get the 
desired effect. 

Examples: 
```julia-repl
julia> 1 |>
           @>  [_ |> @>(_ + 2), 1, 1] |>
               sum
5
```

```julia-repl
julia> 1 |>
           @>  begin
                [1, 1, _ |> @> +(1, 2)] 
                sum
            end
6
```
"""
macro >(code::Expr)
    if code.head == :block
        return :($(esc(rewrite_block(code, rewrite_first_part = true))))
    else
        return :($(esc(rewrite_code(code, rewrite_first_part = true))))
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
5. These rules also apply to macros, with the exception of @> and @>>.`  
6. The input can also be a `begin end block`. A separate function is created for each line in the 
block with result of previous function passed into the next using the re-writing rules. 
7. If there is a sequence of pipe characters within a sequence of pipe characters then a new pipe is 
is created if the first part of the pipe does not contain an underscore so @> [_, 2, sqrt(36) |> _/2] 
is equivalent to x -> [x, 3, sqrt(36) |> y -> y/2]. 

The macro can also be used in itself. Although will often require the use of brackets to get the 
desired effect. 

Examples: 
```julia-repl
julia> 1 |>
           @>  [_ |> @>(_ + 2), 1, 1] |>
               sum
5
```

```julia-repl
julia> 1 |>
           @>  begin
                [1, 1, _ |> @> +(1, 2)] 
                sum
            end
6
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
is equivalent to `@>> "hello world" |> @show(_)` 
6. The macro can also be used in itself. If the @>> appears within itself or @> and _ is in the first 
section of the pipe then it comes from the surrounding context. See the example below.  
7. Instead of pipe characters, |>, separating the different functions that to be created a `begin ... end` 
block can be used with and separate function is created for each line in the block. See the example below. 
7. If there is a sequence of pipe characters within a sequence of pipe characters then a new pipe is 
is created if the first part of the pipe does not contain an underscore so @>> 1 |> [_, 2, sqrt(36) |> _/2]
is equivalent to 1 |> x -> [x, 3, sqrt(36) |> y -> y/2]. 

Examples: 
```julia-repl
julia> @>> 1 |>
            [(@>> _ |> +(1, 2)), 1, 1] |>
            sum
6
```

```julia-repl
julia> @>> begin 
            1 
            [(@>> _ |> _ + 2), 1, 1] 
            sum
        end
5
```
"""
macro >>(code::Expr)
    if code.head == :block
        return :($(esc(rewrite_block(code, rewrite_first_part = false))))
    else 
        return :($(esc(rewrite_code(code, rewrite_first_part = false))))
    end
end

# below should have the same doc string as >>(code::Expr)
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
is equivalent to `@>> "hello world" |> @show(_)` 
6. The macro can also be used in itself. If the @>> appears within itself or @> and _ is in the first 
section of the pipe then it comes from the surrounding context. See the example below.  
7. Instead of pipe characters, |>, separating the different functions that to be created a `begin ... end` 
block can be used with and separate function is created for each line in the block. See the example below. 
7. If there is a sequence of pipe characters within a sequence of pipe characters then a new pipe is 
is created if the first part of the pipe does not contain an underscore so @>> 1 |> [_, 2, sqrt(36) |> _/2]
is equivalent to 1 |> x -> [x, 3, sqrt(36) |> y -> y/2]. 

Examples: 
```julia-repl
julia> @>> 1 |>
            [(@>> _ |> +(1, 2)), 1, 1] |>
            sum
6
```

```julia-repl
julia> @>> begin 
            1 
            [(@>> _ |> _ + 2), 1, 1] 
            sum
        end
5
```
"""
macro >>(code)
    error("@>> can only act on expressions containing a pipe, |>, or a `begin ... end` block not $(typeof(code)).")
end

"""
    @>>(first_arg, pipe::Expr)
    
Rewrites `pipe` into an anonymous function and passes `first_arg` into it. `pipe` must be a `begin ... end` block. 
A function is created for each line in the `begin ... end` block. The result of the previous function is passed 
into the next. 

The pipe is created using the following rules:
1. Underscores are treated as the function argument. `@>> [1,2,3] begin sum(_) end` is equivalent to 
`[1,2,3] |> x -> sum(x)`
2. If the is no underscore in the expression then then the the first argument is imputed,
`@>> [1,2,3] begin .+(3) end` is equivalent to `[1,2,3] |> x -> .+(x, 3)`
3. If expression is a symbol then it is treated as function so `@>> "hello world" begin print end` is interpreted as 
`"hello world" |> x -> print(x)`
4. The above 2 rules are applied to each line of a begin end block. Hence 
```
    @>> 1 begin 
        [_, 1, 2] 
        sum()
    end
``` 
is equivalent to `1 |> x -> [x, 1, 2] |> x -> sum(x)`
5. These rules also applied to macros, with the exception of @> and @>>. Hence `@>> "hello world" begin @show end` 
is equivalent to `"hello world" |> x -> @show(x )` 
6. The macro can also be used in itself. If the @>> appears within itself or @> and _ is in the first 
section of the pipe then it comes from the surrounding context. See the example below.  
7. If there is a sequence of pipe characters within a sequence of pipe characters then a new pipe is 
is created if the first part of the pipe does not contain an underscore so 
```
    @>> 1 begin  
        [_, 2, sqrt(36) |> _/2]
    end 
    
````
is equivalent to 1 |> x -> [x, 3, sqrt(36) |> y -> y/2]. 

Examples: 
```julia-repl
julia> @>> 1 begin
            [(@>> _ |> +(2)), 1, 1] 
            sum
        end
5
```
"""
macro >>(first_arg, pipe::Expr)
    if pipe.head == :block
        pipe.args = [first_arg, pipe.args...]
        return esc(:(@>> $pipe))
    end
    error("When @>> is acting on 2 arguments the second argument must be a \"begin ... end\" block expression.")
end
@>>
# below should have the same docstring as @>>(first_arg, pipe::Expr)
"""
    @>>(first_arg, pipe::Expr)
    
Rewrites `pipe` into an anonymous function and passes `first_arg` into it. `pipe` must be a `begin ... end` block. 
A function is created for each line in the `begin ... end` block. The result of the previous function is passed 
into the next. 

The pipe is created using the following rules:
1. Underscores are treated as the function argument. `@>> [1,2,3] begin sum(_) end` is equivalent to 
`[1,2,3] |> x -> sum(x)`
2. If the is no underscore in the expression then then the the first argument is imputed,
`@>> [1,2,3] begin .+(3) end` is equivalent to `[1,2,3] |> x -> .+(x, 3)`
3. If expression is a symbol then it is treated as function so `@>> "hello world" begin print end` is interpreted as 
`"hello world" |> x -> print(x)`
4. The above 2 rules are applied to each line of a begin end block. Hence 
```
    @>> 1 begin 
        [_, 1, 2] 
        sum()
    end
``` 
is equivalent to `1 |> x -> [x, 1, 2] |> x -> sum(x)`
5. These rules also applied to macros, with the exception of @> and @>>. Hence `@>> "hello world" begin @show end` 
is equivalent to `"hello world" |> x -> @show(x )` 
6. The macro can also be used in itself. If the @>> appears within itself or @> and _ is in the first 
section of the pipe then it comes from the surrounding context. See the example below.  
7. If there is a sequence of pipe characters within a sequence of pipe characters then a new pipe is 
is created if the first part of the pipe does not contain an underscore so 
```
    @>> 1 begin  
        [_, 2, sqrt(36) |> _/2]
    end 
    
````
is equivalent to 1 |> x -> [x, 3, sqrt(36) |> y -> y/2]. 

Examples: 
```julia-repl
julia> @>> 1 begin
            [(@>> _ |> +(2)), 1, 1] 
            sum
        end
5
```
"""
macro >>(first_arg, second_arg)
    error("When @>> is acting on 2 arguments the second argument must be a \"begin ... end\" block expression not $(typeof(second_arg)). ")
end


end #module