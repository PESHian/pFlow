using System.Reflection;
string version = Assembly.GetExecutingAssembly().GetName().Version!.ToString(3);
if (Environment.GetEnvironmentVariable("PFLOW_UPDATER_TEST_FAIL") == version) return 3;
string started = Environment.GetEnvironmentVariable("PFLOW_UPDATER_TEST_STARTED")! + version;
string stop = Environment.GetEnvironmentVariable("PFLOW_UPDATER_TEST_STOP")! + version;
File.WriteAllText(started, Environment.ProcessId.ToString());
while (!File.Exists(stop)) Thread.Sleep(50);
File.Delete(stop);
return 0;
