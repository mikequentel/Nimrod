#
#
#        The Nim Installation Generator
#        (c) Copyright 2014 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

const
  haveZipLib = defined(unix)

when haveZipLib:
  import zipfiles

import
  os, osproc, strutils, parseopt, parsecfg, strtabs, streams, debcreation

const
  maxOS = 20 # max number of OSes
  maxCPU = 10 # max number of CPUs
  buildShFile = "build.sh"
  buildBatFile32 = "build.bat"
  buildBatFile64 = "build64.bat"
  installShFile = "install.sh"
  deinstallShFile = "deinstall.sh"

type
  TAppType = enum appConsole, appGUI
  TAction = enum
    actionNone,   # action not yet known
    actionCSource # action: create C sources
    actionInno,   # action: create Inno Setup installer
    actionNsis,   # action: create NSIS installer
    actionScripts # action: create install and deinstall scripts
    actionZip,    # action: create zip file
    actionDeb     # action: prepare deb package

  TFileCategory = enum
    fcWinBin,     # binaries for Windows
    fcConfig,     # configuration files
    fcData,       # data files
    fcDoc,        # documentation files
    fcLib,        # library files
    fcOther,      # other files; will not be copied on UNIX
    fcWindows,    # files only for Windows
    fcUnix,       # files only for Unix; must be after ``fcWindows``
    fcUnixBin,    # binaries for Unix
    fcDocStart    # links to documentation for Windows installer

  TConfigData = object of TObject
    actions: set[TAction]
    cat: array[TFileCategory, seq[string]]
    binPaths, authors, oses, cpus, downloads: seq[string]
    cfiles: array[1..maxOS, array[1..maxCPU, seq[string]]]
    platforms: array[1..maxOS, array[1..maxCPU, bool]]
    ccompiler, linker, innosetup, nsisSetup: tuple[path, flags: string]
    name, displayName, version, description, license, infile, outdir: string
    libpath: string
    innoSetupFlag, installScript, uninstallScript: bool
    explicitPlatforms: bool
    vars: PStringTable
    app: TAppType
    nimArgs: string
    debOpts: TDebOptions

const
  unixDirVars: array[fcConfig..fcLib, string] = [
    "$configdir", "$datadir", "$docdir", "$libdir"
  ]

proc initConfigData(c: var TConfigData) =
  c.actions = {}
  for i in low(TFileCategory)..high(TFileCategory): c.cat[i] = @[]
  c.binPaths = @[]
  c.authors = @[]
  c.oses = @[]
  c.cpus = @[]
  c.downloads = @[]
  c.ccompiler = ("", "")
  c.linker = ("", "")
  c.innosetup = ("", "")
  c.nsisSetup = ("", "")
  c.name = ""
  c.displayName = ""
  c.version = ""
  c.description = ""
  c.license = ""
  c.infile = ""
  c.outdir = ""
  c.nimArgs = ""
  c.libpath = ""
  c.innoSetupFlag = false
  c.installScript = false
  c.uninstallScript = false
  c.vars = newStringTable(modeStyleInsensitive)

  c.debOpts.buildDepends = ""
  c.debOpts.pkgDepends = ""
  c.debOpts.shortDesc = ""
  c.debOpts.licenses = @[]

proc firstBinPath(c: TConfigData): string =
  if c.binPaths.len > 0: result = c.binPaths[0]
  else: result = ""

proc `\`(a, b: string): string =
  result = if a.len == 0: b else: a & '\\' & b

template toUnix(s: string): string = s.replace('\\', '/')
template toWin(s: string): string = s.replace('/', '\\')

proc skipRoot(f: string): string =
  # "abc/def/xyz" --> "def/xyz"
  var i = 0
  result = ""
  for component in split(f, {DirSep, AltSep}):
    if i > 0: result = result / component
    inc i
  if result.len == 0: result = f

include "inno.tmpl"
include "nsis.tmpl"
include "buildsh.tmpl"
include "buildbat.tmpl"
include "install.tmpl"
include "deinstall.tmpl"

# ------------------------- configuration file -------------------------------

const
  Version = "1.0"
  Usage = "niminst - Nim Installation Generator Version " & Version & """

  (c) 2014 Andreas Rumpf
Usage:
  niminst [options] command[;command2...] ini-file[.ini] [compile_options]
Command:
  csource             build C source code for source based installations
  scripts             build install and deinstall scripts
  zip                 build the ZIP file
  inno                build the Inno Setup installer
  nsis                build the NSIS Setup installer
  deb                 create files for debhelper
Options:
  -o, --output:dir    set the output directory
  --var:name=value    set the value of a variable
  -h, --help          shows this help
  -v, --version       shows the version
Compile_options:
  will be passed to the Nim compiler
"""

proc parseCmdLine(c: var TConfigData) =
  var p = initOptParser()
  while true:
    next(p)
    var kind = p.kind
    var key = p.key
    var val = p.val.string
    case kind
    of cmdArgument:
      if c.actions == {}:
        for a in split(normalize(key.string), {';', ','}):
          case a
          of "csource": incl(c.actions, actionCSource)
          of "scripts": incl(c.actions, actionScripts)
          of "zip": incl(c.actions, actionZip)
          of "inno": incl(c.actions, actionInno)
          of "nsis": incl(c.actions, actionNsis)
          of "deb": incl(c.actions, actionDeb)
          else: quit(Usage)
      else:
        c.infile = addFileExt(key.string, "ini")
        c.nimArgs = cmdLineRest(p).string
        break
    of cmdLongoption, cmdShortOption:
      case normalize(key.string)
      of "help", "h": 
        stdout.write(Usage)
        quit(0)
      of "version", "v": 
        stdout.write(Version & "\n")
        quit(0)
      of "o", "output": c.outdir = val
      of "var":
        var idx = val.find('=')
        if idx < 0: quit("invalid command line")
        c.vars[substr(val, 0, idx-1)] = substr(val, idx+1)
      else: quit(Usage)
    of cmdEnd: break
  if c.infile.len == 0: quit(Usage)

proc walkDirRecursively(s: var seq[string], root: string) =
  for k, f in walkDir(root):
    case k
    of pcFile, pcLinkToFile: add(s, unixToNativePath(f))
    of pcDir: walkDirRecursively(s, f)
    of pcLinkToDir: discard

proc addFiles(s: var seq[string], patterns: seq[string]) =
  for p in items(patterns):
    if existsDir(p):
      walkDirRecursively(s, p)
    else:
      var i = 0
      for f in walkFiles(p):
        add(s, unixToNativePath(f))
        inc(i)
      if i == 0: echo("[Warning] No file found that matches: " & p)

proc pathFlags(p: var TCfgParser, k, v: string,
               t: var tuple[path, flags: string]) =
  case normalize(k)
  of "path": t.path = v
  of "flags": t.flags = v
  else: quit(errorStr(p, "unknown variable: " & k))

proc filesOnly(p: var TCfgParser, k, v: string, dest: var seq[string]) =
  case normalize(k)
  of "files": addFiles(dest, split(v, {';'}))
  else: quit(errorStr(p, "unknown variable: " & k))

proc yesno(p: var TCfgParser, v: string): bool =
  case normalize(v)
  of "yes", "y", "on", "true":
    result = true
  of "no", "n", "off", "false":
    result = false
  else: quit(errorStr(p, "unknown value; use: yes|no"))

proc incl(s: var seq[string], x: string): int =
  for i in 0.. <s.len:
    if cmpIgnoreStyle(s[i], x) == 0: return i
  s.add(x)
  result = s.len-1 

proc platforms(c: var TConfigData, v: string) =
  for line in splitLines(v):
    let p = line.find(": ")
    if p <= 1: continue
    let os = line.substr(0, p-1).strip
    let cpus = line.substr(p+1).strip
    c.oses.add(os)
    for cpu in cpus.split(';'):
      let cpuIdx = c.cpus.incl(cpu)
      c.platforms[c.oses.len][cpuIdx+1] = true

proc parseIniFile(c: var TConfigData) =
  var
    p: TCfgParser
    section = ""
    hasCpuOs = false
  var input = newFileStream(c.infile, fmRead)
  if input != nil:
    open(p, input, c.infile)
    while true:
      var k = next(p)
      case k.kind
      of cfgEof: break
      of cfgSectionStart:
        section = normalize(k.section)
      of cfgKeyValuePair:
        var v = k.value % c.vars
        c.vars[k.key] = v

        case section
        of "project":
          case normalize(k.key)
          of "name": c.name = v
          of "displayname": c.displayName = v
          of "version": c.version = v
          of "os": 
            c.oses = split(v, {';'})
            hasCpuOs = true
            if c.explicitPlatforms:
              quit(errorStr(p, "you cannot have both 'platforms' and 'os'"))
          of "cpu": 
            c.cpus = split(v, {';'})
            hasCpuOs = true
            if c.explicitPlatforms:
              quit(errorStr(p, "you cannot have both 'platforms' and 'cpu'"))
          of "platforms": 
            platforms(c, v)
            c.explicitPlatforms = true
            if hasCpuOs:
              quit(errorStr(p, "you cannot have both 'platforms' and 'os'"))
          of "authors": c.authors = split(v, {';'})
          of "description": c.description = v
          of "app":
            case normalize(v)
            of "console": c.app = appConsole
            of "gui": c.app = appGUI
            else: quit(errorStr(p, "expected: console or gui"))
          of "license": c.license = unixToNativePath(k.value)
          else: quit(errorStr(p, "unknown variable: " & k.key))
        of "var": discard
        of "winbin": filesOnly(p, k.key, v, c.cat[fcWinBin])
        of "config": filesOnly(p, k.key, v, c.cat[fcConfig])
        of "data": filesOnly(p, k.key, v, c.cat[fcData])
        of "documentation":
          case normalize(k.key)
          of "files": addFiles(c.cat[fcDoc], split(v, {';'}))
          of "start": addFiles(c.cat[fcDocStart], split(v, {';'}))
          else: quit(errorStr(p, "unknown variable: " & k.key))
        of "lib": filesOnly(p, k.key, v, c.cat[fcLib])
        of "other": filesOnly(p, k.key, v, c.cat[fcOther])
        of "windows":
          case normalize(k.key)
          of "files": addFiles(c.cat[fcWindows], split(v, {';'}))
          of "binpath": c.binPaths = split(v, {';'})
          of "innosetup": c.innoSetupFlag = yesno(p, v)
          of "download": c.downloads.add(v)
          else: quit(errorStr(p, "unknown variable: " & k.key))
        of "unix":
          case normalize(k.key)
          of "files": addFiles(c.cat[fcUnix], split(v, {';'}))
          of "installscript": c.installScript = yesno(p, v)
          of "uninstallscript": c.uninstallScript = yesno(p, v)
          else: quit(errorStr(p, "unknown variable: " & k.key))
        of "unixbin": filesOnly(p, k.key, v, c.cat[fcUnixBin])
        of "innosetup": pathFlags(p, k.key, v, c.innosetup)
        of "nsis": pathFlags(p, k.key, v, c.nsisSetup)
        of "ccompiler": pathFlags(p, k.key, v, c.ccompiler)
        of "linker": pathFlags(p, k.key, v, c.linker)
        of "deb":
          case normalize(k.key)
          of "builddepends":
            c.debOpts.buildDepends = v
          of "packagedepends", "pkgdepends":
            c.debOpts.pkgDepends = v
          of "shortdesc":
            c.debOpts.shortDesc = v
          of "licenses":
            # file,license;file,license;
            var i = 0
            var file = ""
            var license = ""
            var afterComma = false
            while i < v.len():
              case v[i]
              of ',':
                afterComma = true
              of ';':
                if file == "" or license == "":
                  quit(errorStr(p, "Invalid `licenses` key."))
                c.debOpts.licenses.add((file, license))
                afterComma = false
                file = ""
                license = ""
              else:
                if afterComma: license.add(v[i])
                else: file.add(v[i])
              inc(i)
          else: quit(errorStr(p, "unknown variable: " & k.key))
        else: quit(errorStr(p, "invalid section: " & section))

      of cfgOption: quit(errorStr(p, "syntax error"))
      of cfgError: quit(errorStr(p, k.msg))
    close(p)
    if c.name.len == 0: c.name = changeFileExt(extractFilename(c.infile), "")
    if c.displayName.len == 0: c.displayName = c.name
  else:
    quit("cannot open: " & c.infile)

# ------------------------- generate source based installation ---------------

proc readCFiles(c: var TConfigData, osA, cpuA: int) =
  var p: TCfgParser
  var f = splitFile(c.infile).dir / "mapping.txt"
  c.cfiles[osA][cpuA] = @[]
  var input = newFileStream(f, fmRead)
  var section = ""
  if input != nil:
    open(p, input, f)
    while true:
      var k = next(p)
      case k.kind
      of cfgEof: break
      of cfgSectionStart:
        section = normalize(k.section)
      of cfgKeyValuePair:
        case section
        of "ccompiler": pathFlags(p, k.key, k.value, c.ccompiler)
        of "linker": 
          pathFlags(p, k.key, k.value, c.linker)
          # HACK: we conditionally add ``-lm -ldl``, so remove them from the
          # linker flags:
          c.linker.flags = c.linker.flags.replaceWord("-lm").replaceWord(
                           "-ldl").strip
        else:
          if cmpIgnoreStyle(k.key, "libpath") == 0:
            c.libpath = k.value
      of cfgOption:
        if section == "cfiles" and cmpIgnoreStyle(k.key, "file") == 0:
          add(c.cfiles[osA][cpuA], k.value)
      of cfgError: quit(errorStr(p, k.msg))
    close(p)
  else:
    quit("Cannot open: " & f)

proc buildDir(os, cpu: int): string =
  return "c_code" / ($os & "_" & $cpu)

proc getOutputDir(c: var TConfigData): string =
  if c.outdir.len > 0: c.outdir else: "build"

proc writeFile(filename, content, newline: string) =
  var f: TFile
  if open(f, filename, fmWrite):
    for x in splitLines(content):
      write(f, x)
      write(f, newline)
    close(f)
  else:
    quit("Cannot open for writing: " & filename)

proc removeDuplicateFiles(c: var TConfigData) =
  for osA in countdown(c.oses.len, 1):
    for cpuA in countdown(c.cpus.len, 1):
      if c.cfiles[osA][cpuA].isNil: c.cfiles[osA][cpuA] = @[]
      if c.explicitPlatforms and not c.platforms[osA][cpuA]: continue
      for i in 0..c.cfiles[osA][cpuA].len-1:
        var dup = c.cfiles[osA][cpuA][i]
        var f = extractFilename(dup)
        for osB in 1..c.oses.len:
          for cpuB in 1..c.cpus.len:
            if osB != osA or cpuB != cpuA:
              var orig = buildDir(osB, cpuB) / f
              if existsFile(orig) and existsFile(dup) and
                  sameFileContent(orig, dup):
                # file is identical, so delete duplicate:
                removeFile(dup)
                c.cfiles[osA][cpuA][i] = orig

proc writeInstallScripts(c: var TConfigData) =
  if c.installScript:
    writeFile(installShFile, generateInstallScript(c), "\10")
  if c.uninstallScript:
    writeFile(deinstallShFile, generateDeinstallScript(c), "\10")

proc srcdist(c: var TConfigData) =
  if not existsDir(getOutputDir(c) / "c_code"):
    createDir(getOutputDir(c) / "c_code")
  for x in walkFiles(c.libpath / "lib/*.h"):
    echo(getOutputDir(c) / "c_code" / extractFilename(x))
    copyFile(dest=getOutputDir(c) / "c_code" / extractFilename(x), source=x)
  var winIndex = -1
  var intel32Index = -1
  var intel64Index = -1
  for osA in 1..c.oses.len:
    let osname = c.oses[osA-1]
    if osname.cmpIgnoreStyle("windows") == 0: winIndex = osA
    for cpuA in 1..c.cpus.len:
      if c.explicitPlatforms and not c.platforms[osA][cpuA]: continue
      let cpuname = c.cpus[cpuA-1]
      if cpuname.cmpIgnoreStyle("i386") == 0: intel32Index = cpuA
      elif cpuname.cmpIgnoreStyle("amd64") == 0: intel64Index = cpuA
      var dir = getOutputDir(c) / buildDir(osA, cpuA)
      if existsDir(dir): removeDir(dir)
      createDir(dir)
      var cmd = ("nim compile -f --symbolfiles:off --compileonly " &
                 "--gen_mapping --cc:gcc --skipUserCfg" &
                 " --os:$# --cpu:$# $# $#") %
                 [osname, cpuname, c.nimArgs,
                 changeFileExt(c.infile, "nim")]
      echo(cmd)
      if execShellCmd(cmd) != 0:
        quit("Error: call to nim compiler failed")
      readCFiles(c, osA, cpuA)
      for i in 0 .. c.cfiles[osA][cpuA].len-1:
        let dest = dir / extractFilename(c.cfiles[osA][cpuA][i])
        let relDest = buildDir(osA, cpuA) / extractFilename(c.cfiles[osA][cpuA][i])
        copyFile(dest=dest, source=c.cfiles[osA][cpuA][i])
        c.cfiles[osA][cpuA][i] = relDest
  # second pass: remove duplicate files
  removeDuplicateFiles(c)
  writeFile(getOutputDir(c) / buildShFile, generateBuildShellScript(c), "\10")
  if winIndex >= 0:
    if intel32Index >= 0:
      writeFile(getOutputDir(c) / buildBatFile32,
                generateBuildBatchScript(c, winIndex, intel32Index), "\13\10")
    if intel64Index >= 0:
      writeFile(getOutputDir(c) / buildBatFile64,
                generateBuildBatchScript(c, winIndex, intel64Index), "\13\10")
  writeInstallScripts(c)

# --------------------- generate inno setup -----------------------------------
proc setupDist(c: var TConfigData) =
  let scrpt = generateInnoSetup(c)
  let n = "build" / "install_$#_$#.iss" % [toLower(c.name), c.version]
  writeFile(n, scrpt, "\13\10")
  when defined(windows):
    if c.innosetup.path.len == 0:
      c.innosetup.path = "iscc.exe"
    let outcmd = if c.outdir.len == 0: "build" else: c.outdir
    let cmd = "$# $# /O$# $#" % [quoteShell(c.innosetup.path),
                                 c.innosetup.flags, outcmd, n]
    echo(cmd)
    if execShellCmd(cmd) == 0:
      removeFile(n)
    else:
      quit("External program failed")

# --------------------- generate NSIS setup -----------------------------------
proc setupDist2(c: var TConfigData) =
  let scrpt = generateNsisSetup(c)
  let n = "build" / "install_$#_$#.nsi" % [toLower(c.name), c.version]
  writeFile(n, scrpt, "\13\10")
  when defined(windows):
    if c.nsisSetup.path.len == 0:
      c.nsisSetup.path = "makensis.exe"
    let outcmd = if c.outdir.len == 0: "build" else: c.outdir
    let cmd = "$# $# /O$# $#" % [quoteShell(c.nsisSetup.path),
                                 c.nsisSetup.flags, outcmd, n]
    echo(cmd)
    if execShellCmd(cmd) == 0:
      removeFile(n)
    else:
      quit("External program failed")

# ------------------ generate ZIP file ---------------------------------------
when haveZipLib:
  proc zipDist(c: var TConfigData) =
    var proj = toLower(c.name)
    var n = "$#_$#.zip" % [proj, c.version]
    if c.outdir.len == 0: n = "build" / n
    else: n = c.outdir / n
    var z: TZipArchive
    if open(z, n, fmWrite):
      addFile(z, proj / buildBatFile32, "build" / buildBatFile32)
      addFile(z, proj / buildBatFile64, "build" / buildBatFile64)
      addFile(z, proj / buildShFile, "build" / buildShFile)
      addFile(z, proj / installShFile, installShFile)
      addFile(z, proj / deinstallShFile, deinstallShFile)
      for f in walkFiles(c.libpath / "lib/*.h"):
        addFile(z, proj / "c_code" / extractFilename(f), f)
      for osA in 1..c.oses.len:
        for cpuA in 1..c.cpus.len:
          var dir = buildDir(osA, cpuA)
          for k, f in walkDir("build" / dir):
            if k == pcFile: addFile(z, proj / dir / extractFilename(f), f)

      for cat in items({fcConfig..fcOther, fcUnix}):
        for f in items(c.cat[cat]): addFile(z, proj / f, f)
      close(z)
    else:
      quit("Cannot open for writing: " & n)

# -- prepare build files for .deb creation

proc debDist(c: var TConfigData) =
  if not existsFile(getOutputDir(c) / "build.sh"): quit("No build.sh found.")
  if not existsFile(getOutputDir(c) / "install.sh"): quit("No install.sh found.")
  
  if c.debOpts.shortDesc == "": quit("shortDesc must be set in the .ini file.")
  if c.debOpts.licenses.len == 0:
    echo("[Warning] No licenses specified for .deb creation.")
  
  # -- Copy files into /tmp/..
  echo("Copying source to tmp/niminst/deb/")
  var currentSource = getCurrentDir()
  var workingDir = getTempDir() / "niminst" / "deb"
  var upstreamSource = (c.name.toLower() & "-" & c.version)
  
  createDir(workingDir / upstreamSource)
  
  template copyNimDist(f, dest: string): stmt =
    createDir((workingDir / upstreamSource / dest).splitFile.dir)
    copyFile(currentSource / f, workingDir / upstreamSource / dest)
  
  # Don't copy all files, only the ones specified in the config:
  copyNimDist(buildShFile, buildShFile)
  copyNimDist(installShFile, installShFile)
  createDir(workingDir / upstreamSource / "build")
  for f in walkFiles(c.libpath / "lib/*.h"):
    copyNimDist(f, "build" / extractFilename(f))
  for osA in 1..c.oses.len:
    for cpuA in 1..c.cpus.len:
      var dir = buildDir(osA, cpuA)
      for k, f in walkDir(dir):
        if k == pcFile: copyNimDist(f, dir / extractFilename(f))
  for cat in items({fcConfig..fcOther, fcUnix}):
    for f in items(c.cat[cat]): copyNimDist(f, f)

  # -- Create necessary build files for debhelper.

  let mtnName = c.vars["mtnname"]
  let mtnEmail = c.vars["mtnemail"]

  prepDeb(c.name, c.version, mtnName, mtnEmail, c.debOpts.shortDesc,
          c.description, c.debOpts.licenses, c.cat[fcUnixBin], c.cat[fcConfig],
          c.cat[fcDoc], c.cat[fcLib], c.debOpts.buildDepends,
          c.debOpts.pkgDepends)

# ------------------- main ----------------------------------------------------

var c: TConfigData
initConfigData(c)
parseCmdLine(c)
parseIniFile(c)
if actionInno in c.actions:
  setupDist(c)
if actionNsis in c.actions:
  setupDist2(c)
if actionCSource in c.actions:
  srcdist(c)
if actionScripts in c.actions:
  writeInstallScripts(c)
if actionZip in c.actions:
  when haveZipLib:
    zipDist(c)
  else:
    quit("libzip is not installed")
if actionDeb in c.actions:
  debDist(c)
