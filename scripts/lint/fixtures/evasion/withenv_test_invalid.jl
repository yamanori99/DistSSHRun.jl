withenv(
    "DISTSSH_JOBS" => "nope",
) do
    @test x == 1
end
