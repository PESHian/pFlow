using PFlow.Core;
using System.Text.Json;

internal static class HotkeyChecks
{
    public static void Run()
    {
        int passed = 0;
        void Check(string name, bool value) { if (!value) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }
        bool NoneHeld(uint _) => false;
        string root = Path.Combine(Path.GetTempPath(), "pflow-hotkey-fictional-" + Guid.NewGuid().ToString("N"));
        try {
            Directory.CreateDirectory(root);
            File.WriteAllText(Path.Combine(root, "settings.json"), "{\"templateCatalogVersion\":1,\"language\":\"es\"}");
            var store = new StateStore(root);
            Check("existing settings keep Right Windows and language", store.Preferences.ActivationKey == ActivationKeys.DefaultId && store.Preferences.Language == "es");
            foreach (string? invalid in new[] { null, "", "leftWindows", "rightAlt", "a" }) {
                var preferences = new Preferences { ActivationKey = invalid! }; preferences.Validate();
                Check("unsupported activation choices use safe default", preferences.ActivationKey == ActivationKeys.DefaultId);
            }
            foreach (var choice in ActivationKeys.Choices) {
                store.Preferences.ActivationKey = choice.Id; store.SavePreferences();
                Check(choice.Name + " persists exactly", new StateStore(root).Preferences.ActivationKey == choice.Id);
                var router = new ActivationRouter(choice.Id);
                KeyRoute Event(uint key, bool down, long time, bool injected = false) => router.Process(key, down, injected, time, NoneHeld);
                Check(choice.Name + " injected press ignored", Event(choice.VirtualKey, true, 900, true) == default);
                Check(choice.Name + " hold starts and suppresses key", Event(choice.VirtualKey, true, 1000) == new KeyRoute(TriggerAction.Start, true));
                Check(choice.Name + " auto repeat does not restart", Event(choice.VirtualKey, true, 1100) == new KeyRoute(Consume: true));
                Check(choice.Name + " injected release cannot stop", Event(choice.VirtualKey, false, 1200, true) == default);
                Check(choice.Name + " release stops", Event(choice.VirtualKey, false, 1500) == new KeyRoute(TriggerAction.Stop, true));
                Event(choice.VirtualKey, true, 2000); Event(choice.VirtualKey, false, 2050);
                Check(choice.Name + " double tap enters continuous", Event(choice.VirtualKey, true, 2350).Action == TriggerAction.Continuous);
                Check(choice.Name + " release keeps continuous", Event(choice.VirtualKey, false, 2400).Action == TriggerAction.None && !router.CanRebind);
                Check(choice.Name + " continuous stop press waits", Event(choice.VirtualKey, true, 3000).Action == TriggerAction.None);
                Check(choice.Name + " continuous stop release finishes", Event(choice.VirtualKey, false, 3050).Action == TriggerAction.Stop && router.CanRebind);
                Event(choice.VirtualKey, true, 4000);
                var chord = Event(0x43, true, 4010);
                Check(choice.Name + " chord cancels and replays chosen down", chord.Action == TriggerAction.Cancel && !chord.Consume && chord.Replay == choice);
                router.Reset();
                Check(choice.Name + " replayed key repeat passes through", Event(choice.VirtualKey, true, 4030) == default);
                Check(choice.Name + " replayed key up passes through", Event(choice.VirtualKey, false, 4050) == default && router.CanRebind);
                Event(choice.VirtualKey, true, 5000);
                Check(choice.Name + " Escape cancels without replay", Event(0x1B, true, 5010) == new KeyRoute(TriggerAction.Cancel));
                Check(choice.Name + " cancel ignores repeat until real up", Event(choice.VirtualKey, true, 5020) == new KeyRoute(Consume: true) && Event(choice.VirtualKey, false, 5100) == new KeyRoute(Consume: true));
                Event(choice.VirtualKey, true, 6000); router.Reset();
                Check(choice.Name + " failed capture still preserves later shortcut", Event(0x43, true, 6010).Replay == choice && Event(choice.VirtualKey, false, 6100) == default);
                Check(choice.Name + " preheld Shift bypasses dictation", router.Process(choice.VirtualKey, true, false, 7000, key => key == 0xA0) == default);
                Check(choice.Name + " bypass survives modifier release and repeats", Event(choice.VirtualKey, true, 7100) == default && Event(choice.VirtualKey, false, 7200) == default);
                Event(choice.VirtualKey, true, 8000);
                Check(choice.Name + " disable cancels active capture", router.SetEnabled(false) == TriggerAction.Cancel);
                Check(choice.Name + " disable consumes owed key up", Event(choice.VirtualKey, false, 8100) == new KeyRoute(Consume: true));
                Check(choice.Name + " disabled key works normally", Event(choice.VirtualKey, true, 9000) == default && Event(choice.VirtualKey, false, 9100) == default);
                router.SetEnabled(true);
                Check(choice.Name + " Left Windows remains ordinary", Event(0x5B, true, 10000) == default && Event(0x5B, false, 10100) == default);
            }
            var control = new ActivationRouter("rightControl");
            Check("selected Right Ctrl does not block itself", control.Process(0xA3, true, false, 1000, key => key == 0xA3).Action == TriggerAction.Start);
            bool rejected = false; try { control.Select("f9"); } catch (InvalidOperationException) { rejected = true; }
            Check("held key cannot be rebound", rejected && control.Selected.Id == "rightControl");
            control.Reset();
            Check("canceled key still cannot be rebound before release", !control.CanRebind);
            control.Process(0xA3, false, false, 1200, NoneHeld); control.Select("f9");
            Check("binding changes after release", control.Selected.Id == "f9" && control.Process(0xA3, true, false, 2000, NoneHeld) == default);
            var failed = new ActivationRouter("rightControl");
            failed.Process(0xA3, true, false, 1000, NoneHeld); failed.Process(0x43, true, false, 1010, NoneHeld); failed.ReplayFailed();
            Check("failed replay has no orphan key up", failed.Process(0xA3, false, false, 1050, NoneHeld) == new KeyRoute(Consume: true) && failed.CanRebind);
            var continuous = new ActivationRouter("f9");
            continuous.Process(0x78, true, false, 1000, NoneHeld); continuous.Process(0x78, false, false, 1050, NoneHeld);
            continuous.Process(0x78, true, false, 1100, NoneHeld); continuous.Process(0x78, false, false, 1150, NoneHeld);
            continuous.Process(0x78, true, false, 2000, key => key == 0xA2); continuous.Process(0x78, false, false, 2050, NoneHeld);
            Check("ordinary Ctrl shortcut does not orphan continuous recording", !continuous.CanRebind && continuous.Process(0x78, true, false, 3000, NoneHeld).Action == TriggerAction.None && continuous.Process(0x78, false, false, 3050, NoneHeld).Action == TriggerAction.Stop);
        } finally { Directory.Delete(root, true); }
        Console.WriteLine($"{passed} activation key checks passed.");
    }
}
