using PFlow.Core;

// Older installed copies and the tray menu: pure decisions, fictional paths.
internal static class InstalledChecks
{
    static int passed;
    static void Check(string name, bool value) { if (!value) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }

    public static void Run()
    {
        string root = @"C:\Fixture\Programs\pFlow", current = root + @"\pFlow.exe"; var mine = new Version(0, 1, 18);
        bool Repoint(string? command, string me, Func<string, Version?> versionOf) => InstalledCopies.RunKeyNeedsRepoint(command, me, mine, root, versionOf);
        Check("Run command path drops quotes and arguments", InstalledCopies.CommandPath("\"C:\\Fixture\\Old\\pFlow.exe\" --settings") == @"C:\Fixture\Old\pFlow.exe"
            && InstalledCopies.CommandPath(@"C:\Fixture\Old\pFlow.exe") == @"C:\Fixture\Old\pFlow.exe" && InstalledCopies.CommandPath("  ") == null && InstalledCopies.CommandPath(null) == null);
        Check("a Run key naming a missing pFlow.exe is re-pointed", Repoint("\"C:\\Fixture\\Old\\pFlow.exe\"", current, _ => null));
        Check("a Run key naming an older copy is re-pointed", Repoint("\"C:\\Fixture\\Old\\pFlow.exe\"", current, _ => new Version(0, 1, 17)));
        Check("a Run key naming this copy is left alone", !Repoint("\"c:\\fixture\\programs\\pflow\\PFLOW.EXE\"", current, _ => new Version(0, 1, 18)));
        Check("a Run key naming a newer copy is left alone", !Repoint("\"C:\\Fixture\\Next\\pFlow.exe\"", current, _ => new Version(0, 2, 0)));
        Check("no Run key means nothing to re-point", !Repoint(null, current, _ => null));
        foreach (string elsewhere in new[] { @"C:\Fixture\Temp\pFlow-Windows-Universal-0.1.18\payloads\win-x64\pFlow.exe", @"C:\Fixture\Downloads\pFlow.exe", @"C:\Fixture\Programs\pFlow.new\pFlow.exe", @"C:\Fixture\Programs\pFlowBuild\pFlow.exe" })
            Check("a copy outside the install folder never re-points the key: " + elsewhere, !Repoint("\"C:\\Fixture\\Old\\pFlow.exe\"", elsewhere, _ => null) && !Repoint("\"" + root + "\\pFlow.exe\"", elsewhere, _ => new Version(0, 1, 17)));
        Check("the install folder itself and a nested folder count as installed", InstalledCopies.Inside(current, root) && InstalledCopies.Inside(root + @"\engine\pflow-whisper.exe", root + @"\") && !InstalledCopies.Inside(root + @".new\pFlow.exe", root));
        Check("an older running copy at another path gives way", InstalledCopies.OlderCopyShouldYield(@"C:\Fixture\Old\pFlow.exe", new Version(0, 1, 17), current, mine));
        Check("a copy of this version or newer keeps the single instance", !InstalledCopies.OlderCopyShouldYield(@"C:\Fixture\Old\pFlow.exe", new Version(0, 1, 18), current, mine)
            && !InstalledCopies.OlderCopyShouldYield(@"C:\Fixture\Old\pFlow.exe", new Version(0, 2, 0), current, mine));
        Check("the same file or an unknown version never gives way", !InstalledCopies.OlderCopyShouldYield(current, new Version(0, 1, 17), current, mine)
            && !InstalledCopies.OlderCopyShouldYield(@"C:\Fixture\Old\pFlow.exe", null, current, mine) && !InstalledCopies.OlderCopyShouldYield(null, new Version(0, 1, 17), current, mine));
        Check("the tray menu has Settings and no start item", TrayMenu.Items.Contains(TrayMenu.Settings) && TrayMenu.Items.Contains(TrayMenu.Quit)
            && !TrayMenu.Items.Any(x => x.StartsWith("Start", StringComparison.OrdinalIgnoreCase) || x.Contains("Open pFlow")));
        Console.WriteLine($"{passed} installed copies and tray checks passed.");
    }
}
