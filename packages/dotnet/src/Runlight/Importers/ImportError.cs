using System;

namespace Runlight.Importers;

/// <summary>Why an import stopped, as a code the dashboard says in its own words.</summary>
public class ImportError : Exception
{
    public ImportError()
        : this("Import failed", "import_failed")
    {
    }

    public ImportError(string message)
        : this(message, "import_failed")
    {
    }

    public ImportError(string message, Exception inner)
        : base(message, inner)
    {
        Code = "import_failed";
        Params = [];
    }

    /// <param name="message">The English text.</param>
    /// <param name="code">The string code the dashboard translates.</param>
    /// <param name="parameters">String values for the code; none when null.</param>
    public ImportError(string message, string code, JsObject? parameters = null)
        : base(message)
    {
        Code = code;
        Params = parameters ?? [];
    }

    /// <summary>The string code, as TS's <c>code</c>.</summary>
    public string Code { get; }

    /// <summary>String values the code is said with, as TS's <c>params</c>.</summary>
    public JsObject Params { get; }
}
