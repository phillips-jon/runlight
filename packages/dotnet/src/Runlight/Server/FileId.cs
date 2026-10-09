using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Runlight.Server;

/// <summary>
/// A file's inode number, which .NET does not expose: read from libc's stat, whose <c>st_ino</c> sits 8 bytes in on
/// Linux (x64 and arm64) and macOS alike. On Windows, or where stat cannot be called, it is 0, so a log replaced
/// under the same name is told apart by its first bytes alone.
/// </summary>
internal static class FileId
{
    private static int _how = -1;

    /// <summary>The inode of the file at <paramref name="path"/>. Throws when there is no file there.</summary>
    public static long Of(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException("No such file or directory, stat '" + path + "'", path);
        }
        if (OperatingSystem.IsWindows() || _how == 0)
        {
            return 0;
        }
        byte[] buffer = new byte[512];
        int result;
        try
        {
            // The path as C wants it: UTF-8, ending in a NUL.
            result = Call(System.Text.Encoding.UTF8.GetBytes(path + "\0"), buffer);
        }
        catch (Exception e) when (e is EntryPointNotFoundException or DllNotFoundException)
        {
            _how = 0;
            return 0;
        }
        if (result != 0)
        {
            throw new IOException("Could not read " + path);
        }
        return BitConverter.ToInt64(buffer, 8);
    }

    private static int Call(byte[] path, byte[] buffer)
    {
        if (OperatingSystem.IsMacOS())
        {
            return RuntimeInformation.ProcessArchitecture == Architecture.X64 ? StatInode64(path, buffer) : Stat(path, buffer);
        }
        if (_how is -1 or 1)
        {
            try
            {
                int done = Stat(path, buffer);
                _how = 1;
                return done;
            }
            catch (EntryPointNotFoundException) when (_how == -1)
            {
                // glibc before 2.33 has no stat of its own, only __xstat with a version.
                _how = 2;
            }
        }
        return XStat(RuntimeInformation.ProcessArchitecture == Architecture.X64 ? 1 : 0, path, buffer);
    }

    [DllImport("libc", EntryPoint = "stat")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]
    private static extern int Stat(byte[] path, [Out] byte[] buffer);

    [DllImport("libc", EntryPoint = "stat$INODE64")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]
    private static extern int StatInode64(byte[] path, [Out] byte[] buffer);

    [DllImport("libc", EntryPoint = "__xstat")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.SafeDirectories)]
    private static extern int XStat(int version, byte[] path, [Out] byte[] buffer);
}
