using Test
using DynamicPipe

# basic tests 
@testset "@>, @>> pipeing into one function" begin
    x = [1,2,3]
    
    y = x |>
        @>  sum
    @test y == sum(x)

    y = x |>
        @> sum()
    @test y == sum(x)
        
    y = x |>
        @> sum(_)
    @test y == sum(x)
    
   y = @>> x |> sum
   @test y == sum(x)
   
   y = @>> x |> sum()
   @test y == sum(x)
   
   y = @>> x |> sum(_)
   @test y == sum(x)
    
end

macro double(x)
    return :($(esc(:(x + x))))
end

@testset "@>, @>> test pipeing into macros" begin
    x = [1,2,3]
    y = x + x

    t1 = x |>
        @>  @double()
    t2 = x |>
        @>  @double
    t3 = x |> 
        @>  @double(_) 
        
    @test y == t1
    @test y == t2
    @test y == t3
    
    t1 = @>> x |> @double
    t2 = @>> x |> @double()
    t3 = @>> x |> @double(_)
    
    @test y == t1
    @test y == t2
    @test y == t3
end

@testset "@>, @>> test first arguemnt imputation" begin
    x = [1, 2, 3]
    
    y = copy(x) |> 
        @>  append!(4)
    @test y == [1,2,3,4]
    
    y = @>> copy(x) |>
        append!(4)
    @test y == [1, 2, 3, 4]
end

@testset "@>, @>> test multiple pipes" begin
    x = [1, 2, 3]
    
    y = x |> 
        @>  copy |>
            append!(4)
    @test y == [1,2,3,4]
    
    y = @>> x |>
        copy |> 
        append!(4)
        
    @test y == [1, 2, 3, 4]
end

@testset "@>, @>> test vectorisation" begin
    x = [1,2,3]
    
    y = x |>
        @>  copy() |>
            .+(1)
    @test y == [2,3,4]
    
    y = @>> x |>
        copy() |>
        .+(1)
    
    @test y == [2,3,4]

    x = [1,2,3]
    
    y = x |>
        @>  copy .|>
            +(1)
    
    @test y == [2,3,4]
    
    y = @>> x |>
        copy .|>
        +(1) 
        
    @test y == [2,3,4]
         
end

@testset "@>, @>> test pipes in pipes" begin
    x = [1,2,3]
    z = [1,1,1]
    y_ans = (
        (x + ((x .+ 1) .* 2)) + z .- 1 
    ) 
    
    y = x |> 
        @>  +(x |> 
                @>  _ .+ 1 |>
                    _ .* 2) |>
            _ + z |>
            .-(1)

    @test y == y_ans
    
    y = @>> x |> 
        +(x |> 
            @>  _ .+ 1 |>
                _ .* 2) |>
        _ + z |>
        .-(1)
        
    @test y == y_ans
    
    y = @>> x |> 
        +(@>> x |> 
            _ .+ 1 |>
            _ .* 2) |>
        _ + z |>
        .-(1)
        
    @test y == y_ans
    
    y = @>> x |> 
        +(@>> _ |> 
            _ .+ 1 |>
            _ .* 2) |>
        _ + z |>
        .-(1)
        
    @test y == (
        (((x .+ 1) .* 2) + z) .- 1  
    )
    
    y = @>> x |> 
        _ + @>> _ |> 
            _ .+ 1 |>
            _ .* 2 |>
        _ + z |>
        .-(1)
        
    @test y == y_ans
    
    y = @>> x |> 
            +(_ |> 
                @>  _ .+ 1 |>
                    _ .* 2) |>
            _ + z |>
            .-(1)
        
    @test y == (
        (((x .+ 1) .* 2) + z) .- 1  
    )
    
    y = x |> 
        @>  +(_ |> 
                @>  _ .+ 1 |>
                    _ .* 2) |>
            _ + z |>
            .-(1)
        
    @test y == (
        (((x .+ 1) .* 2) + z) .- 1  
    )
    
    y = x |> 
        @>  _ + (_ |> 
                    @>  _ .+ 1 |>
                        _ .* 2) |>
            _ + z |>
            .-(1)
        
    @test y == y_ans
end

@testset "@>, @>> test block input" begin
    x = [1,2,3]
    z = [1,1,1]
    y_ans = (
        (x + ((x .+ 1) .* 2)) + z .- 1 
    ) 
    
    y = x |> 
        @> begin 
            +(x |> 
                @>  _ .+ 1 |>
                    _ .* 2) 
            _ + z 
            .-(1)
        end

    @test y == y_ans
    
    
    y = x |> 
        @> begin 
            +(x |> 
                @> begin 
                    _ .+ 1 
                    _ .* 2
                end) 
            _ + z 
            .-(1)
        end

    @test y == y_ans
    
    y = @>> begin 
            x 
            +(x |> 
                @>  _ .+ 1 |>
                    _ .* 2) 
            _ + z 
            .-(1)
        end

    @test y == y_ans
    
    y = @>> begin 
            x 
            +(_, _ |> 
                @>  _ .+ 1 |>
                    _ .* 2) 
            _ + z 
            .-(1)
        end

    @test y == y_ans
    
    y = @>> x begin 
            +(x |> 
                @>  _ .+ 1 |>
                    _ .* 2) 
            _ + z 
            .-(1)
        end

    @test y == y_ans
    
    y = @>> x begin 
            +(_, _ |> 
                @>  _ .+ 1 |>
                    _ .* 2) 
            _ + z 
            .-(1)
        end

    @test y == y_ans
    
    y = @>> x begin 
        +(@>> begin x  
            _ .+ 1 
            _ .* 2
        end) 
        _ + z 
        .-(1)
    end
        
    @test y == y_ans
    
    y = @>> x begin 
        +(@>> x begin
            _ .+ 1 
            _ .* 2
        end) 
        _ + z 
        .-(1)
    end
        
    @test y == y_ans 
    
    y = @>> x begin 
        +(_, @>> begin
            _
            _ .+ 1 
            _ .* 2
        end) 
        _ + z 
        .-(1)
    end
    
    @test y == y_ans
    
    y = @>> x begin 
        +(_, @>> _ begin
            _ .+ 1 
            _ .* 2
        end) 
        _ + z 
        .-(1)
    end
    
    @test y == y_ans
end