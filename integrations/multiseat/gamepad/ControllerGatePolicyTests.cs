using MultiSeat.Service.Input;
using Xunit;

namespace MultiSeat.Tests.Input;

public class ControllerGatePolicyTests
{
    const string Pad = @"USB\VID_045E&PID_028E\01";

    [Fact]
    public void UnrelatedUserRulesArePreserved()
    {
        var merged = ControllerGatePolicy.MergeRules(new[] { @"HID\Physical", @"HID\OtherSeat!7" },
            new(StringComparer.OrdinalIgnoreCase), new[] { Pad }, 2);
        Assert.Contains(@"HID\Physical", merged);
        Assert.Contains(@"HID\OtherSeat!7", merged);
        Assert.Contains(Pad + "!2", merged);
        Assert.Equal(3, merged.Count);
    }

    [Theory]
    [InlineData("")]
    [InlineData("!3")]
    [InlineData("!2")]
    public void UnownedRuleCannotBeAdoptedOrReassigned(string suffix)
    {
        var owned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        Assert.Throws<InvalidOperationException>(() => ControllerGatePolicy.MergeRules(
            new[] { Pad.ToLowerInvariant() + suffix }, owned, new[] { Pad }, 2));
        Assert.Empty(owned);
    }

    [Fact]
    public void ReconnectCanReuseOnlyItsJournaledRule()
    {
        var owned = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Pad + "!2" };
        var merged = ControllerGatePolicy.MergeRules(new[] { Pad.ToLowerInvariant() + "!2" }, owned, new[] { Pad }, 2);
        Assert.Single(merged);
    }

    [Fact]
    public void SessionZeroIsRefusedBeforeAddingRules()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => ControllerGatePolicy.MergeRules(
            Array.Empty<string>(), new(), new[] { Pad }, 0));
    }
}
