namespace MultiSeat.Service.Input;

public static class ControllerGatePolicy
{
    public static HashSet<string> MergeRules(IEnumerable<string> existing, HashSet<string> owned,
        IEnumerable<string> paths, int session)
    {
        var result = new HashSet<string>(existing, StringComparer.OrdinalIgnoreCase);
        foreach (var path in paths)
        {
            var rule = HidHideSessionJail.Confine(path, session);
            if (result.Any(r => string.Equals(HidHideSessionJail.Split(r).Path, path, StringComparison.OrdinalIgnoreCase) && !owned.Contains(r)))
                throw new InvalidOperationException("Device has a foreign HidHide rule");
            result.Add(rule);
        }
        return result;
    }
}
