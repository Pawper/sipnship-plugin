# Windows Search index rules for one folder, through the indexer's own interface
# for a user's rules (ISearchCrawlScopeManager). No administrator rights.
#   search-index.ps1 check FOLDER    prints "out", "in" or "unknown"
#   search-index.ps1 exclude FOLDER  adds an exclusion rule, prints "out" or "unknown"
# Only reads or adds one rule; never removes anything.
param([string]$Action, [string]$Folder)
$ErrorActionPreference = 'Stop'
$src = @'
using System;
using System.Runtime.InteropServices;
namespace SipSearch {
  [ComImport, Guid("AB310581-AC80-11D1-8DF3-00C04FB6EF69"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface ISearchManager {
    void GetIndexerVersionStr([MarshalAs(UnmanagedType.LPWStr)] out string v);
    void GetIndexerVersion(out uint hi, out uint lo);
    void GetParameter([MarshalAs(UnmanagedType.LPWStr)] string n, out IntPtr v);
    void SetParameter([MarshalAs(UnmanagedType.LPWStr)] string n, IntPtr v);
    void get_ProxyName([MarshalAs(UnmanagedType.LPWStr)] out string v);
    void get_BypassList([MarshalAs(UnmanagedType.LPWStr)] out string v);
    void SetProxy(int a, int b, [MarshalAs(UnmanagedType.LPWStr)] string c, [MarshalAs(UnmanagedType.LPWStr)] string d);
    void GetCatalog([MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.Interface)] out ISearchCatalogManager c);
    void get_UserAgent([MarshalAs(UnmanagedType.LPWStr)] out string v);
    void put_UserAgent([MarshalAs(UnmanagedType.LPWStr)] string v);
    void get_UseProxy(out int v);
    void get_LocalBypass(out int v);
    void get_PortNumber(out uint v);
  }
  [ComImport, Guid("AB310581-AC80-11D1-8DF3-00C04FB6EF50"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface ISearchCatalogManager {
    void get_Name([MarshalAs(UnmanagedType.LPWStr)] out string v);
    void GetParameter([MarshalAs(UnmanagedType.LPWStr)] string n, out IntPtr v);
    void SetParameter([MarshalAs(UnmanagedType.LPWStr)] string n, IntPtr v);
    void GetCatalogStatus(out int s, out int p);
    void Reset();
    void Reindex();
    void ReindexMatchingURLs([MarshalAs(UnmanagedType.LPWStr)] string p, uint f);
    void ReindexSearchRoot([MarshalAs(UnmanagedType.LPWStr)] string p);
    void put_ConnectTimeout(uint v);
    void get_ConnectTimeout(out uint v);
    void put_DataTimeout(uint v);
    void get_DataTimeout(out uint v);
    void NumberOfItems(out int n);
    void NumberOfItemsToIndex(out int a, out int b, out int c);
    void URLBeingIndexed([MarshalAs(UnmanagedType.LPWStr)] out string v);
    void GetURLIndexingState([MarshalAs(UnmanagedType.LPWStr)] string u, out uint s);
    void GetPersistentItemsChangedSink([MarshalAs(UnmanagedType.Interface)] out object o);
    void RegisterViewForNotification([MarshalAs(UnmanagedType.LPWStr)] string a, IntPtr b, out uint c);
    void GetItemsChangedSink(IntPtr a, ref Guid g, out IntPtr b, out IntPtr c, out IntPtr d);
    void UnregisterViewForNotification(uint c);
    void SetExtensionClusion([MarshalAs(UnmanagedType.LPWStr)] string e, int x);
    void EnumerateExcludedExtensions(out IntPtr o);
    void GetQueryHelper(out IntPtr o);
    void put_DiacriticSensitivity(int v);
    void get_DiacriticSensitivity(out int v);
    void GetCrawlScopeManager([MarshalAs(UnmanagedType.Interface)] out ISearchCrawlScopeManager m);
  }
  [ComImport, Guid("6292F7AD-4E19-4717-A534-8FC22BCD5CCD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface ISearchCrawlScopeManager {
    void AddDefaultScopeRule([MarshalAs(UnmanagedType.LPWStr)] string u, int inc, uint f);
    void AddRoot(IntPtr r);
    void RemoveRoot([MarshalAs(UnmanagedType.LPWStr)] string u);
    void EnumerateRoots(out IntPtr o);
    void AddHierarchicalScope([MarshalAs(UnmanagedType.LPWStr)] string u, int inc, int dflt, int ovr);
    void AddUserScopeRule([MarshalAs(UnmanagedType.LPWStr)] string u, int inc, int ovr, uint f);
    void RemoveScopeRule([MarshalAs(UnmanagedType.LPWStr)] string u);
    void EnumerateScopeRules(out IntPtr o);
    void HasParentScopeRule([MarshalAs(UnmanagedType.LPWStr)] string u, out int h);
    void HasChildScopeRule([MarshalAs(UnmanagedType.LPWStr)] string u, out int h);
    void IncludedInCrawlScope([MarshalAs(UnmanagedType.LPWStr)] string u, out int i);
    void IncludedInCrawlScopeEx([MarshalAs(UnmanagedType.LPWStr)] string u, out int i, out int reason);
    void RevertToDefaultScopes();
    void SaveAll();
    void GetParentScopeVersionId([MarshalAs(UnmanagedType.LPWStr)] string u, out int v);
    void RemoveDefaultScopeRule([MarshalAs(UnmanagedType.LPWStr)] string u);
  }
  public static class Scope {
    public static ISearchCrawlScopeManager Open() {
      Type t = Type.GetTypeFromCLSID(new Guid("7D096C5F-AC08-4F1F-BEB7-5C22C517CE39"));
      ISearchManager m = (ISearchManager)Activator.CreateInstance(t);
      ISearchCatalogManager c; m.GetCatalog("SystemIndex", out c);
      ISearchCrawlScopeManager s; c.GetCrawlScopeManager(out s);
      return s;
    }
    public static bool Included(string url) { int i; Open().IncludedInCrawlScope(url, out i); return i != 0; }
    public static void Exclude(string url) { var s = Open(); s.AddUserScopeRule(url, 0, 1, 0); s.SaveAll(); }
  }
}
'@
try {
  Add-Type -TypeDefinition $src -ErrorAction Stop
  $full = (Resolve-Path -LiteralPath $Folder -ErrorAction Stop).Path.TrimEnd('\') + '\'
  $url = 'file:///' + $full
  if ($Action -eq 'exclude') {
    if ([SipSearch.Scope]::Included($url)) { [SipSearch.Scope]::Exclude($url) }
  }
  if ([SipSearch.Scope]::Included($url)) { 'in' } else { 'out' }
} catch { 'unknown' }
