# README
 
DynamicPipe is designed to best replicate magrittr's pipe operator, `%>%`, from R in Julia. The below R code
```R
library(tidyverse)

star_wars_summary <- starwars %>%
  group_by(species) %>%
  summarise(N = n()
            ,mass = mean(mass, na.rm = TRUE)) %>%
  filter(N > 1
         ,mass > 50) %>% 
  mutate(proportion = N/sum(N)) %>% 
  arrange(desc(proportion))
```
is eqivelant to 
```julia
using DataFrames, DataFramesMeta, DynamicPipe, Statistics
# assuming the data is already loaded in

starwars_summary = starwars |>
    @>  groupby(:species) |>
        @combine(N = length(:species)
                 ,mass = mean(:mass |> skipmissing)) |>
        @where(:N .> 1
               ,:mass .> 50) |>
        @transform(proportion = :N ./ sum(:N)) |>
        @orderby(-:proportion)
```

. Dynamic Pipes gives similar functionality to other Julia piping packages only it allows for continuos typing without the need to call a macro before you start writing the pipe. This means the user does not have to move the cursor back to the to the start of text they typed in order to pipe it into a function. This is achieved through the `@>` macro. 

## `@>` 
This macro creates an anonymous function using similar rewriting rules as R's `%>%`. The following rules apply to macros and functions. 
1. Whatever is on the left of a `|>` or `.|>` is passed into the function of the right of the `|>` or `.|>`.
1. Underscores are used to represent the argument that is passed into the function. Hence `2 |> @> sqrt(_)` is equivalent to `2 |> x -> sqrt(x)` which is equivalent to `sqrt(2)`.
2. If there is no underscore then the argument is assumed the be the first argument of the function call. Hence, `2 |> @> +(2)` is equivalent to `+(2, 2)`. The following lines,
    ```julia
    2 |> 
        @>  sqrt()
        
    #and
    
    2 |>
        @>  sqrt 
    ```
    are both equivalent to `2 |> x -> sqrt(x)`.
3. Separate anonymous functions are created for expressions between `|>` and `.|>` with expression on the left piped into the expression on the right hence,
    ```julia
    2 |>
        @>  _ + 2 |>
            sqrt()
    ```
    is equivalent to 
    ```julia 
    2 |>
        x -> x + 2 |>
        x -> sqrt(x)
    ```
    and returns `2`.
4. The only macro that `@>` doesn't act on is itself and `@>>`. This allows for pipes within pipes so
    ```julia
    2 |>
        @>  [√1, √_, 3 |> @> √_] |>
            sum()
    ```
    is equivalent to 
    ```julia
    2 |>
        x -> [√1, √x, 3 |> y -> √y] |>
        x -> sum(x)
    ```
5. If the first element in a sequency of pipe charecters does not contain an underscore then a new pipe is formed. So
    ```julia
    2 |>
        @>  [_, 3, 4 |> _/2]
    ```
    is equivalent to `[2, 3, 4/2]` not `[2, 3, 2/2]`.
    
Like [Chain.jl](https://github.com/jkrumbiegel/Chain.jl) the `@>` macro also supports `begin ... end` block syntax so you don't have to keep typing `|>`. Hence,
```julia
2 |> 
    @> begin
    _ + 2
    sqrt()
end
```
is equivalent to 
```julia
2 |> 
    @>  _ + 2 |>
        sqrt()
```
Begin end block syntax can only be used to define the outermost pipe so 
```julia
2 |>
    @> begin
        [_, 3, begin 
                4 
                _/2
            end]
    end
```
is not equivalent to  
```julia
    2 |>
        @>  [_, 3, 4 |> _/2]
```
## `@>>`
The package also contains a `@>>` macro that follows most of the same rules as `@>` only it is used at the beginning of pipes.
```julia
@>> 2 |>
    _ + 2 |>
    sqrt()
```
is equivalent to 
```julia
2 |> 
    @>  _ + 2 |>
        sqrt()
```
. In order to allow pipes within pipes underscores are allowed in the first part of the pipe. Hence 
```julia 
2 |>
    @>  [√1, √_, @>> _ |> √(_ + 1)] |>
        sum()
``` 
is equivalent to 
```julia
2 |>
    x -> [√1, √x, x |> y -> √(y + 1)] |>
    x -> sum(x)
```
. `@>>` supports `begin ... end` block syntax in two ways. Both 
```julia 
@>> 2 begin
    _ + 2 
    sqrt()
end
```
and 
```julia
@>> begin
    2
    _ + 2 
    sqrt()
end
```
are equivalent to 
```julia 
2 |>
    @>  _ + 2 |>
        sqrt()
```
.
