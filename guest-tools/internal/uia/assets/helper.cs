using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace Alcove
{
    public static class UiaHelper
    {
        public static void Run()
        {
            UTF8Encoding utf8 = new UTF8Encoding(false);
            StreamReader input = new StreamReader(Console.OpenStandardInput(), utf8);
            StreamWriter output = new StreamWriter(Console.OpenStandardOutput(), utf8);
            output.AutoFlush = true;
            output.NewLine = "\n";
            JavaScriptSerializer json = new JavaScriptSerializer();
            json.MaxJsonLength = int.MaxValue;
            output.WriteLine("{\"ev\":\"ready\"}");

            string line;
            while ((line = input.ReadLine()) != null)
            {
                if (line.Length == 0)
                {
                    continue;
                }
                Dictionary<string, object> reply = new Dictionary<string, object>();
                try
                {
                    Dictionary<string, object> req = json.Deserialize<Dictionary<string, object>>(line);
                    object id = null;
                    req.TryGetValue("id", out id);
                    reply["id"] = id;
                    object opValue = null;
                    req.TryGetValue("op", out opValue);
                    string op = opValue as string;
                    if (op == "ping")
                    {
                        reply["ok"] = true;
                        reply["pong"] = true;
                        reply["clr"] = Environment.Version.ToString();
                    }
                    else
                    {
                        reply["ok"] = false;
                        reply["error"] = "unknown op '" + op + "'";
                    }
                }
                catch (Exception e)
                {
                    reply["ok"] = false;
                    reply["error"] = "bad request: " + e.Message;
                }
                output.WriteLine(json.Serialize(reply));
            }
        }
    }
}
