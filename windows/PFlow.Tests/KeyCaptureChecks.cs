using PFlow.Core;

internal static class KeyCaptureChecks
{
    public static void Run()
    {
        int passed=0;
        void Check(string label,bool value) { if(!value) throw new Exception("FAIL: "+label);passed++;Console.WriteLine("PASS: "+label); }
        string root=Path.Combine(Path.GetTempPath(),"pflow-learn-fictional-"+Guid.NewGuid().ToString("N"));
        try {
            var store=new StateStore(root);
            foreach(var (vk,scan,extended) in new (uint,uint,bool)[] { (0xA5,0x38,true),(0xA2,0x1D,false),(0xA3,0x1D,true),(0x5D,0x5D,true),(0xB6,0x6B,true),(0xB7,0x21,true),(0xE8,0x65,false),(0xFF,0x7E,false),(0x41,0x1E,false),(0x0D,0x1C,true),(0x0D,0x1C,false),(0x7C,0x64,false),(0xA4,0x38,false),(0xA0,0x2A,false),(0xA1,0x36,false),(0x5B,0x5B,true) }) {
                var capture=new KeyCapture();
                CaptureRoute Event(bool down,long time,bool injected=false)=>capture.Process(vk,scan,extended,down,injected,time);
                Check("learn ignores injected event",Event(true,900,true)==default);
                Check("learn consumes down without selecting",Event(true,1000)==new CaptureRoute(true));
                Check("learn repeat does not complete",Event(true,1100)==new CaptureRoute(true));
                var selected=Event(false,1400).Key;
                Check("learn only selects on release",selected!=null && capture.Drained);
                store.Preferences.ActivationKey=selected!.Id;store.SavePreferences();
                Check("learned identity persists and validates",new StateStore(root).Preferences.ActivationKey==selected.Id);
                var router=new ActivationRouter(selected.Id);
                KeyRoute Route(bool down,long time)=>router.Process(vk,down,false,time,_=>false,scan,extended);
                Check("learned key starts hold",Route(true,2000)==new KeyRoute(TriggerAction.Start,true));
                Check("learned key stops hold",Route(false,2400)==new KeyRoute(TriggerAction.Stop,true));
                Route(true,3000);Route(false,3050);
                Check("learned key double tap starts continuous",Route(true,3100).Action==TriggerAction.Continuous);
                Route(false,3150);Route(true,4000);
                Check("learned key tap stops continuous",Route(false,4050).Action==TriggerAction.Stop);
            }
            foreach(string invalid in new[]{"key:1B:01:0","key:01:00:0","key:100:00:0","key:41:123:0","key:41:01:2","key:GG:00:0","key:10:00:0","key:41:00:0:extra"})
                Check("invalid custom identity uses default",ActivationKeys.Resolve(invalid).Id==ActivationKeys.DefaultId);
            var letter=ActivationKeys.FromEvent(0x5A,0x2C);
            Check("physical identity survives keyboard layout change",new ActivationRouter(letter.Id).Process(0x59,true,false,1000,_=>false,0x2C,false).Action==TriggerAction.Start);
            var enter=ActivationKeys.FromEvent(0x0D,0x1C,false);var numEnter=ActivationKeys.FromEvent(0x0D,0x1C,true);
            Check("main and numpad Enter stay distinct",enter.Id!=numEnter.Id && new ActivationRouter(numEnter.Id).Process(0x0D,true,false,1000,_=>false,0x1C,false)==default);
            var held=new KeyCapture([0xA2]);
            Check("keys already held keep their original up",held.Process(0xA2,0x1D,false,false,false,1000)==default);
            var waiting=new KeyCapture([0xA2]);
            var interrupted=waiting.Process(0x41,0x1E,false,true,false,1000);
            Check("key pressed while waiting cancels without consuming its down",!interrupted.Consume&&interrupted.Issue!=null&&waiting.Drained);
            waiting.Process(0xA2,0x1D,false,false,false,1100);
            Check("forwarded held key repeat is not learned",waiting.Process(0x41,0x1E,false,true,false,1200)==default);
            Check("forwarded held key keeps its release",waiting.Process(0x41,0x1E,false,false,false,1300)==default);
            var fresh=new KeyCapture();fresh.Process(0x41,0x1E,false,true,false,1400);
            Check("fresh selection after all forwarded releases can be learned",fresh.Process(0x41,0x1E,false,false,false,1500).Key?.VirtualKey==0x41);
            foreach(bool numpadFirst in new[]{true,false}) {
                var shared=new KeyCapture([0x0D]);
                Check("same-VK second physical key cancels without taking its down",shared.Process(0x0D,0x1C,true,true,false,1600) is {Consume:false,Issue:not null});
                shared.Process(0x0D,0x1C,numpadFirst,false,false,1700);
                Check("both Enter release orders keep the remaining repeat and up",shared.Process(0x0D,0x1C,!numpadFirst,true,false,1800)==default && shared.Process(0x0D,0x1C,!numpadFirst,false,false,1900)==default && shared.Drained);
            }
            var repeating=new KeyCapture([0xA2]);
            Check("initial held repeat cancels without consuming",repeating.Process(0xA2,0x1D,false,true,false,2000) is {Consume:false,Issue:not null});
            Check("initial repeat cancellation reports once and keeps original up",repeating.Process(0xA2,0x1D,false,true,false,2100)==default&&repeating.Process(0xA2,0x1D,false,false,false,2200)==default);
            foreach(uint opening in new uint[]{0x0D,0x20}) {
                var opened=new KeyCapture([opening]);opened.Process(opening,0,false,false,false,2300);opened.Process(0x41,0x1E,false,true,false,2400);
                Check("opening Enter or Space release permits a fresh selection",opened.Process(0x41,0x1E,false,false,false,2500).Key?.VirtualKey==0x41);
            }
            var cancel=new KeyCapture();cancel.Process(0x41,0x1E,false,true,false,1000);cancel.Cancel();
            Check("cancel still owns repeats",cancel.Process(0x41,0x1E,false,true,false,1100).Consume);
            Check("cancel preserves other typing",cancel.Process(0x42,0x30,false,true,false,1200)==default);
            Check("cancel drains suppressed up",cancel.Process(0x41,0x1E,false,false,false,1300).Consume && cancel.Drained);
            var escape=new KeyCapture();escape.Process(0x41,0x1E,false,true,false,1000);
            Check("Escape cancels selection",escape.Process(0x1B,1,false,true,false,1100).Issue!=null);
            escape.Process(0x41,0x1E,false,false,false,1200);
            Check("Escape cancellation retains its owned up",escape.Process(0x1B,1,false,false,false,1300).Consume && escape.Drained);
            var chord=new KeyCapture();chord.Process(0xA2,0x1D,false,true,false,1000);
            Check("chords are rejected without saving a partial key",chord.Process(0x43,0x2E,false,true,false,1050).Issue!=null);
            chord.Process(0x43,0x2E,false,false,false,1100);chord.Process(0xA2,0x1D,false,false,false,1200);
            Check("rejected chord drains both ups",chord.Drained);
            var altGr=new KeyCapture();altGr.Process(0xA2,0x1D,false,true,false,1000);altGr.Process(0xA5,0x38,true,true,false,1000);
            Check("AltGr waits for companion release",altGr.Process(0xA5,0x38,true,false,false,1100).Key==null);
            Check("AltGr learns Right Alt rather than synthetic Ctrl",altGr.Process(0xA2,0x1D,false,false,false,1100).Key?.Id=="rightAlt");
            var ordinary=new ActivationRouter("rightAlt");
            Check("real modifier before Right Alt preserves shortcut",ordinary.Process(0xA5,true,false,1000,k=>k==0xA2)==default);
        } finally { Directory.Delete(root,true); }
        Console.WriteLine($"{passed} learned-key core checks passed.");
    }
}
