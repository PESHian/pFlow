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
        Check("pFlow.exe inside an unpacked package is not installed, so it must say so instead of running", InstalledCopies.RunsFromPackage(@"C:\Fixture\Downloads\pFlow-Windows-Universal-0.1.19-testing\payloads\win-x64\pFlow.exe")
            && InstalledCopies.RunsFromPackage(@"C:\Fixture\Local\pFlow.setup-abc\payloads\win-arm64\pFlow.exe") && InstalledCopies.RunsFromPackage("C:/Fixture/x/PAYLOADS/WIN-X86/pFlow.exe"));
        Check("the install folder, a build folder and a plain Downloads copy are not packages", !InstalledCopies.RunsFromPackage(current) && !InstalledCopies.RunsFromPackage(@"C:\Fixture\src\windows\dist\win-x64\pFlow.exe") && !InstalledCopies.RunsFromPackage(@"C:\Fixture\Downloads\pFlow.exe"));
        Check("the tray menu has Settings and no start item", TrayMenu.Items.Contains(TrayMenu.Settings) && TrayMenu.Items.Contains(TrayMenu.Quit)
            && !TrayMenu.Items.Any(x => x.StartsWith("Start", StringComparison.OrdinalIgnoreCase) || x.Contains("Open pFlow")));
        Check("the couldn't-type card is needed for every outcome that did not put the words in, never for an inserted take or words typed live",
            InsertionPrompt.Needed("Saved to History. Open History to copy your dictation.", false) && InsertionPrompt.Needed("Focus changed. Your text is in History.", false)
            && InsertionPrompt.Needed("Dictation is off in password fields.", false) && InsertionPrompt.Needed("Insertion could not be confirmed; check the field before copying from History.", false)
            && !InsertionPrompt.Needed("Inserted", false) && !InsertionPrompt.Needed("Inserted as plain text; bold headings could not be applied safely.", false)
            && !InsertionPrompt.Needed("Inserted, but it could not be copied to the clipboard. Copy it from History.", false) && !InsertionPrompt.Needed("Kept as typed", true));
        Check("the card's reason line drops the 'in History' trailer and never comes out empty",
            InsertionPrompt.Reason("Focus changed. Your text is in History.") == "Focus changed." && InsertionPrompt.Reason("Saved to History. Open History to copy your dictation.") == "Saved to History."
            && InsertionPrompt.Reason("Couldn't reach that box. Your words are in History.") == "Couldn't reach that box." && InsertionPrompt.Reason("Dictation is off in password fields.") == "Dictation is off in password fields."
            && InsertionPrompt.Reason("  Your text is in History. ") == "The words could not go into that box.");
        Check("the start notice names the tray and the activation key", StartNotice.Body("Right Ctrl") == "Find it in the tray, near the clock. Hold Right Ctrl and speak; let go to put the words in." && StartNotice.Title == "pFlow is running");
        { var values = UninstallEntry.Values(current, root, new Version(0, 1, 20), 760L * 1024 * 1024 + 1, new DateTimeOffset(2026, 10, 21, 9, 0, 0, TimeSpan.Zero));
          Check("the Installed apps row names pFlow by Pesh, Pesh, the version, the icon, the folder, the size in KB and a no-admin uninstall command",
              (string)values["DisplayName"] == "pFlow by Pesh" && (string)values["Publisher"] == "Pesh" && (string)values["DisplayVersion"] == "0.1.20" && (string)values["DisplayIcon"] == current + ",0"
              && (string)values["InstallLocation"] == root && (string)values["InstallDate"] == "20261021" && (string)values["UninstallString"] == "\"" + current + "\" --uninstall"
              && (string)values["QuietUninstallString"] == "\"" + current + "\" --uninstall --quiet" && (int)values["EstimatedSize"] == 760 * 1024 + 1 && (int)values["NoModify"] == 1 && (int)values["NoRepair"] == 1
              && UninstallEntry.KeyPath == @"Software\Microsoft\Windows\CurrentVersion\Uninstall\pFlow by Pesh");
          Check("a version without a build number shows 0, never -1", (string)UninstallEntry.Values(current, root, new Version(1, 2), 0, DateTimeOffset.UnixEpoch)["DisplayVersion"] == "1.2.0"); }
        Check("uninstall removes only pFlow's own folders under Programs", UninstallEntry.OwnsFolder("pFlow") && UninstallEntry.OwnsFolder("pflow.new") && UninstallEntry.OwnsFolder("pFlow.previous-abc")
            && UninstallEntry.OwnsFolder("pFlow.failed-abc") && !UninstallEntry.OwnsFolder("pFlowOther") && !UninstallEntry.OwnsFolder("Microsoft VS Code") && !UninstallEntry.OwnsFolder("pFlow Setup"));
        Console.WriteLine($"{passed} installed copies and tray checks passed.");
    }
}
