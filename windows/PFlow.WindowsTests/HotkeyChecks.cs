using PFlow.Core;
using TriggerAction = PFlow.Core.TriggerAction;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Threading;
using System.Windows.Media;

internal static partial class Program
{
    static void Drain()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }
    static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T result) yield return result;
            foreach (var nested in Descendants<T>(child)) yield return nested;
        }
    }
    static void NativeHotkeys()
    {
        _ = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var actions = new List<TriggerAction>(); var replayed = new List<Native.Input>();
        using var hook = new KeyboardHook(actions.Add, "rightControl", inputs => replayed.AddRange(inputs), _ => false);
        bool Event(uint vk, bool down, long time, uint flags = 0) {
            bool consumed = hook.ProcessKey(new Native.HookKey { Vk = vk, Flags = flags }, down, time); Drain(); return consumed;
        }
        Check("injected physical routing never starts capture", !Event(0xA3, true, 900, 0x10) && actions.Count == 0);
        Check("generic extended Ctrl routes to Right Ctrl", Event(0x11, true, 1000, 1) && actions.SequenceEqual(new[] { TriggerAction.Start }));
        Check("unselected real key forwards after replay", !Event(0x43, true, 1020));
        Check("Right Ctrl replay has native extended flag", replayed.Count == 1 && replayed[0].Data.Keyboard.Vk == 0xA3 && replayed[0].Data.Keyboard.Flags == Native.KEYEVENTF_EXTENDEDKEY && actions.Last() == TriggerAction.Cancel);
        hook.Reset(); Check("replayed Ctrl up passes after application cancellation", !Event(0x11, false, 1100, 1));
        hook.SelectActivationKey("f9");
        actions.Clear();
        Check("old key no longer activates", !Event(0xA3, true, 2000) && !Event(0xA3, false, 2050) && actions.Count == 0);
        Check("chosen F9 starts and stops", Event(0x78, true, 3000) && Event(0x78, false, 3500) && actions.SequenceEqual(new[] { TriggerAction.Start, TriggerAction.Stop }));
        using (var blockedReplay = new KeyboardHook(_ => {}, "rightControl", _ => throw new InvalidOperationException("Fictional blocked input"), _ => false)) {
            blockedReplay.ProcessKey(new Native.HookKey { Vk = 0xA3 }, true, 4000);
            Check("blocked replay cannot type an unmodified shortcut letter", blockedReplay.ProcessKey(new Native.HookKey { Vk = 0x43 }, true, 4010));
            Check("blocked replay suppresses its unmatched modifier release", blockedReplay.ProcessKey(new Native.HookKey { Vk = 0xA3 }, false, 4100));
        }
        hook.Enabled = false;
        string directory = Path.Combine(Path.GetTempPath(), "pflow-hotkey-ui-fictional-" + Guid.NewGuid().ToString("N"));
        var store = new StateStore(directory); bool busy = false;
        hook.SelectActivationKey(store.Preferences.ActivationKey);
        SettingsWindow Make(StateStore data, KeyboardHook keys) => new(data, new Whisper(directory), new LocalTextModel(directory), keys, () => { }, () => busy);
        var window = Make(store, hook);
        try {
            window.Show(); window.UpdateLayout(); Drain();
            ComboBox Picker(SettingsWindow view) => Descendants<ComboBox>(view).Single(control => AutomationProperties.GetName(control) == "Activation key");
            void Choose(ComboBox picker, string id) {
                picker.BringIntoView();
                var parent = (ComboBoxAutomationPeer)UIElementAutomationPeer.CreatePeerForElement(picker);
                var expand = (IExpandCollapseProvider)parent.GetPattern(PatternInterface.ExpandCollapse);
                expand.Expand();
                try {
                    picker.UpdateLayout(); Drain();
                    var children = parent.GetChildren() ?? new List<AutomationPeer>();
                    var item = children.OfType<ListBoxItemAutomationPeer>().SingleOrDefault(peer => peer.Item is ActivationKey key && key.Id == id);
                    if (item == null) throw new InvalidOperationException($"No activation item {id}; children: " + string.Join(", ", children.Select(peer => $"{peer.GetType().Name}: {(peer as ItemAutomationPeer)?.Item}")));
                    string expected = ActivationKeys.Resolve(id).Name, actual = item.GetName();
                    if (actual != expected) throw new InvalidOperationException($"Activation item {id}: expected UIA name '{expected}', got '{actual}'");
                    ((ISelectionItemProvider)item.GetPattern(PatternInterface.SelectionItem)).Select();
                } finally { expand.Collapse(); Drain(); }
            }
            var picker = Picker(window);
            Check("accessible picker offers useful keys without Right Windows", picker.Items.Cast<ActivationKey>().Any(key => key.Id == "rightControl") && picker.Items.Cast<ActivationKey>().Any(key => key.Id == "f9"));
            Choose(picker, "f9");
            Check("native picker changes saved preference and active listener", new StateStore(directory).Preferences.ActivationKey == "f9" && hook.ActivationKey == "f9");
            Check("help names the selected activation key", Descendants<TextBlock>(window).Any(text => text.Text.StartsWith("Hold F9 to dictate.")));
            busy = true; Choose(picker, "rightControl");
            Check("busy picker keeps current shortcut", picker.SelectedValue as string == "f9" && new StateStore(directory).Preferences.ActivationKey == "f9" && hook.ActivationKey == "f9");
            busy = false; hook.Enabled = true; Event(0x78, true, 6000);
            Choose(picker, "rightControl");
            Check("held key cannot be changed through Settings", picker.SelectedValue as string == "f9" && hook.ActivationKey == "f9");
            Event(0x78, false, 6500); hook.Enabled = false;
            Directory.CreateDirectory(Path.Combine(directory, "settings.json.new"));
            Choose(picker, "rightControl");
            Check("save failure preserves active and saved shortcut", picker.SelectedValue as string == "f9" && hook.ActivationKey == "f9" && new StateStore(directory).Preferences.ActivationKey == "f9");
            Directory.Delete(Path.Combine(directory, "settings.json.new"));
            window.Close();
            var reopenedStore = new StateStore(directory);
            using var reopenedHook = new KeyboardHook(_ => {}, reopenedStore.Preferences.ActivationKey) { Enabled = false };
            window = Make(reopenedStore, reopenedHook); window.Show(); window.UpdateLayout(); Drain();
            Check("relaunch restores picker and listener", Picker(window).SelectedValue as string == "f9" && reopenedHook.ActivationKey == "f9");
        } finally { window.Close(); Directory.Delete(directory, true); }
    }
}
