module DynamicPipes

import Chain

export @>>
export @> 

#TODO write own version of chain as we can't use pipe in 
# @>> 2 begin 
#   sqrt
#   sum([_, @>> _ |> sqrt]) 
#end

2 |> @> begin 
    sqrt 
    [_, 6, 7]
    sum(2)
end

# fuction to impute the first part of @>> if it contains underscores 
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
        new_code, contains_underscore = rewrite_function_internal(pipe_subsection, new_arg, impute_as_first_arg = false)
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

    new_code = copy(code)
    contains_underscore = false
        
    #TODO replace this with a dict 
    loop_start_point = new_code.head ∈ [:call, :kw] ? min(2, length(new_code.args)) :
                       new_code.head == :macrocall ? min(3, length(new_code.args)) : 
                       1

    # loop through replacing underscores with the new argument         
    for (location, arg) in [enumerate(new_code.args)...][loop_start_point:end]
        if arg == :_
            new_code.args[location] =  new_arg
            contains_underscore = true 
        elseif arg isa Expr
            if arg.head ≠ :macrocall || (arg.head == :macrocall && arg.args[1] ∉ excluded_macros)
                new_code.args[location], had_underscore = rewrite_function_internal(arg, new_arg, impute_as_first_arg = false)
                contains_underscore = had_underscore || contains_underscore
            elseif arg.head == :macrocall && arg.args[1] == Symbol("@>>")
                new_code.args[location], contains_underscore = replace_first_part_of_pipe(arg, new_arg)
            end
        end
    end
    
    # if does not conatin and we are imputeing the first arguemnt
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
    # if we are at the start of the pipe 
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
    #TODO raise an error if evaluate_pipe == true and we get here 
    return :($new_arg ->  $(rewrite_function_internal(code, new_arg)[1]))
end


function rewrite_code(code::Symbol)
    new_arg = gensym(:_)
    return :($new_arg -> $(rewrite_function_internal(code, new_arg)[1]))
end

function rewrite_code(code)
    @assert false "@> and @>> can only act on Symbols and Expressions not $(typeof(code))"
end

# convert block of code to a function 
function rewrite_block(code)
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
                        evaluate_pipe = false)
    else
        return :($new_arg ->  $(rewrite_function_internal(functions[1], new_arg)[1]))
    end
end

macro >(code::Symbol)
    return :($(rewrite_code(code)))
end

macro >(code)
    if code.head == :block
        return :($(rewrite_block(code)))
    else
        return :($(rewrite_code(code)))
    end
end

macro >>(code)
    if code isa Expr
        if code.head == :block
            return :(@chain($code))
        end
    end
    return :($(rewrite_code(code, evaluate_pipe = true)))
end


macro >>(inital_value, block::Expr)
    :(@chain($inital_value, $block))
end
  
end #module