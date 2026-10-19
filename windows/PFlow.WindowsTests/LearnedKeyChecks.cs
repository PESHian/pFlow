using PFlow.Core;
using PFlow.Windows;
using TriggerAction = PFlow.Core.TriggerAction;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;

internal static partial class Program
{
    static void NativeKeyCapture()
    {
        var actions=new List<TriggerAction>();var replay=new List<Native.Input>();
        using var hook=new KeyboardHook(actions.Add,"rightControl",inputs=>replay.AddRange(inputs),_=>false);
        var learned=new List<ActivationKey>();hook.KeyCaptured+=(_,key,_)=>{if(key!=null)learned.Add(key);};
        bool Event(uint vk,uint scan,bool down,long time,uint flags=0) { bool result=hook.ProcessKey(new Native.HookKey{Vk=vk,Scan=scan,Flags=flags,Time=(uint)time},down,time);Drain();return result; }
        foreach(var (vk,scan,flags) in new (uint,uint,uint)[]{(0x12,0x38,1),(0x11,0x1D,0),(0x5D,0x5D,1),(0xB6,0x6B,1),(0xE8,0x65,0),(0x41,0x1E,0),(0x10,0x36,0)}) {
            hook.BeginKeyCapture();int count=learned.Count;
            Check("native learning suppresses press and repeat",Event(vk,scan,true,1000,flags)&&Event(vk,scan,true,1100,flags)&&learned.Count==count&&actions.Count==0);
            Check("native learning completes only after release",Event(vk,scan,false,1300,flags)&&learned.Count==count+1&&!hook.Capturing&&actions.Count==0);
            hook.SelectActivationKey(learned.Last().Id);
        }
        hook.SelectActivationKey(ActivationKeys.FromEvent(0x41,0x1E).Id);
        Event(0x41,0x1E,true,2000);Event(0x43,0x2E,true,2100);Event(0x41,0x1E,false,2200);
        Check("learned chord replays its scan before forwarding the next key",replay.Count==1&&replay[0].Data.Keyboard.Vk==0&&replay[0].Data.Keyboard.Scan==0x1E&&replay[0].Data.Keyboard.Flags==8&&actions.Last()==TriggerAction.Cancel);
        actions.Clear();hook.Enabled=false;
        hook.BeginKeyCapture();Event(0x41,0x1E,true,3000);hook.CancelKeyCapture();
        Check("closed picker still suppresses its owned release",Event(0x41,0x1E,false,3100)&&!hook.Capturing&&actions.Count==0);
        var product=(PFlow.Windows.Program)Application.Current;
        const System.Reflection.BindingFlags members=System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic;
        typeof(PFlow.Windows.Program).GetField("keyboard",members)!.SetValue(product,hook);
        hook.BeginKeyCapture();
        typeof(PFlow.Windows.Program).GetMethod("OnTrigger",members)!.Invoke(product,[TriggerAction.Continuous]);
        Check("capsule cannot start microphone during key selection",typeof(PFlow.Windows.Program).GetField("recorder",members)!.GetValue(product)==null);
        hook.CancelKeyCapture();
        using(var altGr=new KeyboardHook(actions.Add,"rightAlt",inputs=>replay.AddRange(inputs),key=>key==0xA2)) {
            actions.Clear();replay.Clear();
            bool Alt(uint vk,uint scan,bool down,uint stamp,uint flags=0){bool value=altGr.ProcessKey(new Native.HookKey{Vk=vk,Scan=scan,Time=stamp,Flags=flags},down,stamp);Drain();return value;}
            Alt(0xA2,0x1D,true,4000);Check("Right Alt starts with synthetic AltGr companion",Alt(0x12,0x38,true,4000,1)&&actions.Last()==TriggerAction.Start);
            Check("AltGr character forwards with replayed Right Alt",!Alt(0x51,0x10,true,4100)&&actions.Last()==TriggerAction.Cancel&&replay.Single().Data.Keyboard.Vk==0xA5&&replay.Single().Data.Keyboard.Flags==1);
            Check("AltGr replay releases remain paired",!Alt(0x12,0x38,false,4200,1)&&!Alt(0xA2,0x1D,false,4200));
            actions.Clear();Alt(0xA2,0x1D,true,4300,0x10);Alt(0x12,0x38,true,4300,1);Alt(0x12,0x38,false,4400,1);Alt(0xA2,0x1D,false,4400,0x10);
            Check("injected AltGr companion still permits a real Right Alt hold",actions.SequenceEqual(new[]{TriggerAction.Start,TriggerAction.Stop}));
        }
        actions.Clear();string root=Path.Combine(Path.GetTempPath(),"pflow-learn-ui-fictional-"+Guid.NewGuid().ToString("N"));
        bool heldEnter=true;
        using(var waiting=new KeyboardHook(actions.Add,"rightControl",_=>{},key=>key==0x0D&&heldEnter)) {
            var results=new List<(ActivationKey?key,string?issue)>();waiting.KeyCaptured+=(_,key,issue)=>results.Add((key,issue));
            bool Waiting(bool down,uint flags,uint stamp) {bool result=waiting.ProcessKey(new Native.HookKey{Vk=0x0D,Scan=0x1C,Flags=flags,Time=stamp},down,stamp);Drain();return result;}
            Waiting(true,0,4410);Waiting(true,1,4420);bool rejected=false;
            try {waiting.BeginKeyCapture();} catch(InvalidOperationException error) {rejected=error.Message.StartsWith("Release held keys");}
            Check("both Enter keys held refuse capture without changing the shortcut",rejected&&!waiting.Capturing&&waiting.CanRebind&&waiting.ActivationKey=="rightControl");
            Check("refused capture forwards original releases and remaining repeat",!Waiting(false,1,4600)&&!Waiting(true,0,4700)&&!Waiting(false,0,4800)&&results.Count==0&&actions.Count==0);
            heldEnter=false;waiting.BeginKeyCapture();Waiting(true,1,4810);Waiting(false,1,4820);
            Check("released keys permit a fresh native selection",results.Count==1&&results[0].key?.VirtualKey==0x0D&&!waiting.Capturing);
        }
        try {
            var store=new StateStore(root);hook.SelectActivationKey(store.Preferences.ActivationKey);bool busy=false;
            SettingsWindow Make(StateStore data)=>new(data,new Whisper(root),new LocalTextModel(root),hook,()=>{},()=>busy);
            var window=Make(store);
            void Click(string name) {
                var button=Descendants<Button>(window).Single(x=>x.Content as string==name || AutomationProperties.GetName(x)==name);button.BringIntoView();
                ((IInvokeProvider)UIElementAutomationPeer.CreatePeerForElement(button).GetPattern(PatternInterface.Invoke)).Invoke();Drain();
            }
            ComboBox Picker()=>Descendants<ComboBox>(window).Single(x=>AutomationProperties.GetName(x)=="Activation key");
            try {
                window.Show();window.UpdateLayout();Drain();
                foreach(var opening in new[]{System.Windows.Input.Key.Enter,System.Windows.Input.Key.Space}) {
                    var button=Descendants<Button>(window).Single(x=>x.Content as string=="Press a key");button.BringIntoView();button.Focus();Drain();
                    var down=new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice,PresentationSource.FromVisual(button),1,opening){RoutedEvent=System.Windows.Input.Keyboard.PreviewKeyDownEvent};button.RaiseEvent(down);
                    Check("opening Enter or Space does not start capture on down",down.Handled&&!hook.Capturing);
                    var up=new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice,PresentationSource.FromVisual(button),2,opening){RoutedEvent=System.Windows.Input.Keyboard.PreviewKeyUpEvent};button.RaiseEvent(up);
                    Check("opening Enter or Space starts capture on release",up.Handled&&hook.Capturing);Click("Cancel key selection");
                }
                Click("Press a key");
                Check("native press-key control starts while dictation is disabled",hook.Capturing&&!hook.Enabled&&!Picker().IsEnabled);
                Event(0x7C,0x64,true,5000);Check("Settings does not save a held candidate",store.Preferences.ActivationKey==ActivationKeys.DefaultId);
                Event(0x7C,0x64,false,5100);
                string custom=ActivationKeys.FromEvent(0x7C,0x64).Id;
                Check("native release saves custom key and updates help",new StateStore(root).Preferences.ActivationKey==custom&&hook.ActivationKey==custom&&Picker().SelectedValue as string==custom&&Descendants<TextBlock>(window).Any(x=>x.Text.StartsWith("Hold "+KeyLabels.Name(ActivationKeys.Resolve(custom))+" to dictate.")));
                busy=true;Click("Press a key");Check("busy app refuses learning",!hook.Capturing&&store.Preferences.ActivationKey==custom);busy=false;
                Click("Press a key");Event(0x1B,1,true,5200);Event(0x1B,1,false,5300);
                Check("Escape restores the previous key and picker",!hook.Capturing&&Picker().IsEnabled&&new StateStore(root).Preferences.ActivationKey==custom);
                Click("Press a key");Click("Dictionary");
                Check("navigation cancels hidden key picker and preserves typed letters",!hook.Capturing&&!Event(0x41,0x1E,true,5310)&&!Event(0x41,0x1E,false,5320)&&new StateStore(root).Preferences.ActivationKey==custom);
                Click("Back");Click("Press a key");Event(0x41,0x1E,true,5330);Click("Dictionary");
                Check("cached navigation drains an owned release without saving",Event(0x41,0x1E,false,5340)&&!hook.Capturing&&new StateStore(root).Preferences.ActivationKey==custom);
                Click("Back");
                Directory.CreateDirectory(Path.Combine(root,"settings.json.new"));Click("Press a key");Event(0x5D,0x5D,true,5400,1);Event(0x5D,0x5D,false,5500,1);
                Check("learned save failure restores saved and active key",hook.ActivationKey==custom&&Picker().SelectedValue as string==custom&&new StateStore(root).Preferences.ActivationKey==custom);
                Directory.Delete(Path.Combine(root,"settings.json.new"));
                Click("Press a key");Event(0x41,0x1E,true,5600);window.Close();
                Check("Settings close drains held key without changing the shortcut",Event(0x41,0x1E,false,5700)&&!hook.Capturing&&hook.ActivationKey==custom);
                window=Make(new StateStore(root));window.Show();window.UpdateLayout();Drain();
                Check("relaunch restores custom picker item",Picker().SelectedValue as string==custom&&Picker().Items.Cast<ActivationKey>().Any(x=>x.Id==custom));
                Click("Press a key");Event(0x41,0x1E,true,5800);window.WindowState=WindowState.Minimized;Drain();Event(0x41,0x1E,false,5900);
                Check("minimizing cancels capture and drains release",!hook.Capturing&&hook.ActivationKey==custom);
            } finally {window.Close();}
        } finally {Directory.Delete(root,true);}
    }
}
