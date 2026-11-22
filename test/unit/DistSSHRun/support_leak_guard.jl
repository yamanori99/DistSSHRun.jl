@testset "leak guard state" begin
    before = (env = Dict("A" => "1"), load = ["x"], proj = "/p")
    after = (env = Dict("A" => "2"), load = ["x"], proj = "/p")
    msgs = _leak_guard_state_messages(before, after)
    @test length(msgs) == 1
    @test occursin("ENV[A]", msgs[1])
    @test occursin("1", msgs[1])
    @test occursin("2", msgs[1])
end
