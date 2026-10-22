using PFlow.Core;
using PFlow.Windows;
using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Interop;

internal static partial class Program
{
    static void NativeInsertion()
    {
        // Unchecked typing into a Chromium pane: a line break is Shift+Enter (never Enter, which sends a chat message).
        var typed = Native.TypedText("ab\ncd");
        Check("typed text keeps every character and turns a line break into Shift+Enter", typed.Length == 2 * 4 + 4
            && typed.Take(4).All(x => (x.Data.Keyboard.Flags & Native.KEYEVENTF_UNICODE) != 0)
            && typed[4].Data.Keyboard.Vk == 0x10 && (typed[4].Data.Keyboard.Flags & Native.KEYEVENTF_KEYUP) == 0
            && typed[5].Data.Keyboard.Vk == 0x0D && (typed[5].Data.Keyboard.Flags & Native.KEYEVENTF_KEYUP) == 0
            && typed[6].Data.Keyboard.Vk == 0x0D && (typed[6].Data.Keyboard.Flags & Native.KEYEVENTF_KEYUP) != 0
            && typed[7].Data.Keyboard.Vk == 0x10 && (typed[7].Data.Keyboard.Flags & Native.KEYEVENTF_KEYUP) != 0
            && typed.All(x => x.Data.Keyboard.Vk != 0x0D || x.Data.Keyboard.Scan == 0)
            && Native.TypedText("one line").Length == 16 && Native.TypedText("a\r\nb\rc").Length == 2 + 4 + 2 + 4 + 2);
        _ = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var editor = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
        AutomationProperties.SetAutomationId(editor, "FictionalInsertionField");
        var window = new Window { Title = "pFlow fictional caret fixture", Width = 480, Height = 240, Content = editor };
        try {
            window.Show(); window.UpdateLayout(); Drain();
            _ = UIElementAutomationPeer.CreatePeerForElement(editor);
            var handle = new WindowInteropHelper(window).Handle;
            Clipboard.SetText("Private fictional clipboard — keep this untouched.");
            uint clipboard = Native.GetClipboardSequenceNumber();
            bool Apply(string expected, int caret, Action? guard = null)
            {
                var work = Task.Run(() => {
                    var root = AutomationElement.FromHandle(handle);
                    var field = root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, "FictionalInsertionField")) ?? throw new Exception("Native editor automation unavailable.");
                    var value = (ValuePattern)field.GetCurrentPattern(ValuePattern.Pattern);
                    return InsertionTarget.ApplyPlainValue(field, value, expected, caret, guard ?? (() => { }));
                });
                var deadline = Stopwatch.StartNew();
                while (!work.IsCompleted && deadline.Elapsed < TimeSpan.FromSeconds(10)) { Drain(); Thread.Sleep(1); }
                Check("keystrokes are safe for a Win32 control, or for text with no line break elsewhere (chat apps send on Enter)",
                    InsertionTarget.TypingSafe(true, "two\nlines") && InsertionTarget.TypingSafe(false, "one line") && !InsertionTarget.TypingSafe(false, "two\nlines") && !InsertionTarget.TypingSafe(false, "two\rlines"));
                Check("native field operation completes", work.IsCompleted);
                return work.GetAwaiter().GetResult();
            }
            void Insert(string name, string words)
            {
                int start = editor.SelectionStart, selected = editor.SelectionLength;
                var state = new FieldState(1, 1, "fixture", editor.Text, start, selected);
                var payload = InsertionTarget.Prepare(state, words);
                int caret = start + payload.Text.Length;
                Check(name + " confirms actual field text", Apply(payload.Expected, caret) && TextProcessing.SameText(editor.Text, payload.Expected));
                Drain();
                Check(name + " leaves collapsed caret after dictation", editor.SelectionLength == 0 && TextProcessing.SameText(editor.Text[..editor.CaretIndex], payload.Expected[..caret]));
                Check(name + " leaves private clipboard unchanged", Native.GetClipboardSequenceNumber() == clipboard);
            }
            Insert("first narration", "Morgan checked the blue bicycle.");
            Insert("second narration without clicking", "Alex checked the red helmet.");
            Insert("third narration without clicking", "Both items were returned.");
            Check("repeated dictation retains sentence order and spaces", editor.Text == "Morgan checked the blue bicycle. Alex checked the red helmet. Both items were returned.");
            editor.Text = "Before. After."; editor.Select(8, 0);
            Insert("middle-of-text narration", "Morgan arrived.");
            Check("middle insertion keeps following text", editor.Text == "Before. Morgan arrived. After.");
            editor.Text = "Before. Replace this. After."; editor.Select(8, 13);
            Insert("selected-text replacement", "Alex arrived.");
            editor.Text = ""; editor.Select(0, 0);
            Insert("Unicode paragraphs", "Zoë met 李明 👋🏽.\n\nCafe\u0301 stayed open.");
            Insert("narration after Unicode paragraphs", "The total was 42.");
            editor.Text = ""; editor.Select(0, 0);
            Insert("long Unicode narration", string.Concat(Enumerable.Repeat("Morgan noted the blue bicycle 👮. ", 600)).TrimEnd());
            Insert("narration after long text", "Alex signed the form.");
            const string final = "Morgan checked the blue bicycle.";
            editor.Text = "";
            Check("newer user caret is not moved", !Apply(final, final.Length, () => window.Dispatcher.Invoke(() => editor.Select(2, 0))) && editor.CaretIndex == 2);
            editor.Text = "";
            Check("newer user edit is not overwritten", !Apply(final, final.Length, () => window.Dispatcher.Invoke(() => editor.AppendText(" User edit."))) && editor.Text == final + " User edit.");
            editor.Text = "";
            bool blocked = false;
            try { Apply(final, final.Length, () => throw new InvalidOperationException("Fictional focus changed.")); }
            catch (InvalidOperationException e) when (e.Message == "Fictional focus changed.") { blocked = true; }
            Check("focus guard blocks caret movement", blocked && editor.CaretIndex == 0);
            Check("all caret safeguards leave clipboard unchanged", Native.GetClipboardSequenceNumber() == clipboard);
        } finally { window.Close(); }
    }
}
