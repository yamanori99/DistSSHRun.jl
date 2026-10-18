using Test

# Julia 1.14 only. Looked up by name so 1.13 never resolves them.
const _SIGINT_CANCELS = isdefined(Base, :CANCEL_TOKEN)
_sigint_base(name::Symbol) = getglobal(Base, Base.inferencebarrier(name))

# A cancelled `Base.CANCEL_TOKEN` value, as after Ctrl-C on Julia 1.14.
function _sigint_test_cancelled_token(; cancelled::Bool = true)
    src = _sigint_base(:CancellationTokenSource)()
    tok = _sigint_base(:CancellationToken)(src)
    cancelled && _sigint_base(:cancel!)(src, _sigint_base(:CANCEL_REQUEST_SAFE))
    return src, _sigint_base(:CANCEL_TOKEN) => tok
end

@testset "sigint" begin
    @testset "is_sigint" begin
        @test DistSSHBase.is_sigint(InterruptException())
        @test !DistSSHBase.is_sigint(ErrorException("x"))
        @test DistSSHBase.is_sigint(LoadError("x.jl", 1, InterruptException()))
        @test !DistSSHBase.is_sigint(LoadError("x.jl", 1, ErrorException("x")))
        t = @task throw(InterruptException())
        schedule(t)
        e = try
            wait(t)
        catch err
            err
        end
        @test DistSSHBase.is_sigint(e)
        @test DistSSHBase.is_sigint(CompositeException([ErrorException("x"), e]))
        @test !DistSSHBase.is_sigint(CompositeException([ErrorException("x")]))
        if _SIGINT_CANCELS
            req = _sigint_base(:CANCEL_REQUEST_SAFE)
            @test DistSSHBase.is_sigint(req)
            @test DistSSHBase.is_sigint(LoadError("x.jl", 1, req))
        end
    end

    @testset "shield_sigint" begin
        @test DistSSHBase.shield_sigint(() -> 7) == 7
        if _SIGINT_CANCELS
            src, scope = _sigint_test_cancelled_token(; cancelled = false)
            ticks = Ref(0)
            t = Base.ScopedValues.with(scope) do
                @async DistSSHBase.shield_sigint() do
                    for _ in 1:5
                        sleep(0.05)
                        ticks[] += 1
                    end
                    return :done
                end
            end
            sleep(0.08)
            _sigint_base(:cancel!)(src, _sigint_base(:CANCEL_REQUEST_SAFE))
            @test fetch(t) === :done
            @test ticks[] == 5
        end
    end

    @testset "without_cancel" begin
        @test DistSSHBase.without_cancel(() -> 7) == 7
        if _SIGINT_CANCELS
            _, scope = _sigint_test_cancelled_token()
            r = Base.ScopedValues.with(scope) do
                @test_throws _sigint_base(:CancellationRequest) sleep(0.01)
                return DistSSHBase.without_cancel() do
                    sleep(0.01)
                    return :cleaned
                end
            end
            @test r === :cleaned
        end
    end
end
