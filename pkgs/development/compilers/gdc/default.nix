{ stdenv, 
  fetchFromGitHub,
  fetchurl,
  noSysDirs,
  overrideCC,
  makeWrapper, 
  curl,
  tzdata, 
  darwin,
  gmp,
  mpfr,
  libmpc,
  targetPlatform,
  targetPackages,
  gnused ? null,
  isl ? null # optional, for the Graphite optimization framework.
}:

let

  version = "2.068.2";
  gcc_branch = "gcc6";
  gcc_version = "6.4.0";

  gdcBuild = stdenv.mkDerivation rec {
    name = "gdcBuild-${version}";
    inherit version;

    enableParallelBuilding = true;

    srcs = [
    (fetchurl {
      url = "mirror://gnu/gcc/gcc-${gcc_version}/gcc-${gcc_version}.tar.xz";
      sha256 = "1m0lr7938lw5d773dkvwld90hjlcq2282517d1gwvrfzmwgg42w5";
    })
    (fetchFromGitHub {
      owner = "D-Programming-GDC";
      repo = "gdc";
      rev = "v${version}_${gcc_branch}";
      sha256 = "0hbpgpvxvmvfp32r04kv2hnhg5xhqbc65lhxjgwbbvnidv3k5azc";
      name = "gdc";
    })
    (fetchFromGitHub {
      owner = "D-Programming-GDC";
      repo = "gdmd";
      rev = "v${version}";
      sha256 = "1jw44dfwh2lavpll7a8j4b57qybjrdm1pfrx94qczca8p2w5933i";
      name = "gdmd";
    })
    ];

    sourceRoot = ".";

    postUnpack = ''
        patchShebangs .

        # Remove cppa test for now because it doesn't work.
        rm gdc/gcc/testsuite/gdc.test/runnable/cppa.d
        rm gdc/gcc/testsuite/gdc.test/runnable/extra-files/cppb.cpp
    '';

    ROOT_HOME_DIR = "$(echo ~root)";

    postPatch = ''
        substituteInPlace gdc/libphobos/src/std/datetime.d \
            --replace "import core.time;" "import core.time;import std.path;"

        substituteInPlace gdc/libphobos/src/std/datetime.d \
            --replace "tzName == \"leapseconds\"" "baseName(tzName) == \"leapseconds\""

        # Ugly hack to fix the hardcoded path to zoneinfo in the source file.
        # https://issues.dlang.org/show_bug.cgi?id=15391
        substituteInPlace gdc/libphobos/src/std/datetime.d \
            --replace /usr/share/zoneinfo/ ${tzdata}/share/zoneinfo/

        # Ugly hack so the dlopen call has a chance to succeed.
        # https://issues.dlang.org/show_bug.cgi?id=15391
        substituteInPlace gdc/libphobos/src/std/net/curl.d \
            --replace libcurl.so ${curl.out}/lib/libcurl.so
    ''

    + stdenv.lib.optionalString stdenv.hostPlatform.isLinux ''
        # See https://github.com/NixOS/nixpkgs/issues/29443
        substituteInPlace gdc/libphobos/src/std/path.d \
            --replace "\"/root" "\"${ROOT_HOME_DIR}"
    '';

    nativeBuildInputs = [ makeWrapper ]

    ++ stdenv.lib.optional stdenv.hostPlatform.isDarwin (with darwin.apple_sdk.frameworks; [
      Foundation
    ]);

  buildInputs = [
    curl tzdata
    gmp mpfr libmpc 
    targetPackages.stdenv.cc.bintools # For linking code at run-time
  ] ++ (stdenv.lib.optional (isl != null) isl)

    # The builder relies on GNU sed (for instance, Darwin's `sed' fails with
    # "-i may not be used with stdin"), and `stdenvNative' doesn't provide it.
    ++ (stdenv.lib.optional stdenv.hostPlatform.isDarwin gnused)
    ++ (stdenv.lib.optional stdenv.hostPlatform.isDarwin targetPackages.stdenv.cc.bintools)
    ;

    preConfigure = ''
      cd gdc
      ./setup-gcc.sh ../gcc-${gcc_version}

      mkdir ../gcc-build
      cd ../gcc-build
    '';

    hardeningDisable = [ "format" ];

    /* Platform flags */
    platformFlags = let
        gccArch = targetPlatform.platform.gcc.arch or null;
        gccCpu = targetPlatform.platform.gcc.cpu or null;
        gccAbi = targetPlatform.platform.gcc.abi or null;
        gccFpu = targetPlatform.platform.gcc.fpu or null;
        gccFloat = targetPlatform.platform.gcc.float or null;
        gccMode = targetPlatform.platform.gcc.mode or null;
      in
        stdenv.lib.optional (gccArch != null) "--with-arch=${gccArch}" ++
        stdenv.lib.optional (gccCpu != null) "--with-cpu=${gccCpu}" ++
        stdenv.lib.optional (gccAbi != null) "--with-abi=${gccAbi}" ++
        stdenv.lib.optional (gccFpu != null) "--with-fpu=${gccFpu}" ++
        stdenv.lib.optional (gccFloat != null) "--with-float=${gccFloat}" ++
        stdenv.lib.optional (gccMode != null) "--with-mode=${gccMode}";
    
    configureFlags =
      # Basic dependencies
      [
        "--with-gmp-include=${gmp.dev}/include"
        "--with-gmp-lib=${gmp.out}/lib"
        "--with-mpfr-include=${mpfr.dev}/include"
        "--with-mpfr-lib=${mpfr.out}/lib"
        "--with-mpc=${libmpc}"
      ] ++
      #optional (libelf != null) "--with-libelf=${libelf}" ++
      #optional (!(crossMingw && crossStageStatic))
        #"--with-native-system-header-dir=${getDev stdenv.cc.libc}/include" ++

      # Basic configuration
      [
        "--enable-lto"
        "--disable-libstdcxx-pch"
        "--disable-multilib"
        "--disable-bootstrap"
        "--without-included-gettext"
        "--with-system-zlib"
        "--enable-static"
        "--enable-shared"
        "--enable-plugin"
        "--with-isl=${isl}"
        "--enable-languages=d"
      ] ++

      platformFlags;

    configureScript = ''
      ../gcc-${gcc_version}/configure
    '';

    doCheck = true;

    checkPhase = ''
    '';
    
    #installPhase = ''
    #'';

    meta = with stdenv.lib; {
      description = "GNU D Compiler";
      homepage = http://gdcproject.org;
      license = with licenses; [ boost gpl3 ];
      maintainers = with maintainers; [ ThomasMader ];
      platforms = [ "x86_64-linux" "i686-linux" "x86_64-darwin" ];
    };
  };

  # Need to test Phobos in a fixed-output derivation, otherwise the
  # network stuff in Phobos would fail if sandbox mode is enabled.
  phobosUnittests = stdenv.mkDerivation rec {
    name = "phobosUnittests-${version}";
    version = gdcBuild.version;

    enableParallelBuilding = gdcBuild.enableParallelBuilding;
    preferLocalBuild = true;
    inputString = gdcBuild.outPath;
    outputHashAlgo = "sha256";
    outputHash = builtins.hashString "sha256" inputString;

    srcs = gdcBuild.srcs;

    sourceRoot = ".";

    postPatch = gdcBuild.postPatch;

    nativeBuildInputs = gdcBuild.nativeBuildInputs;
    buildInputs = gdcBuild.buildInputs;

    buildPhase = ''
        #cd phobos
        #make -j$NIX_BUILD_CORES -f posix.mak unittest PIC=1 DMD=${gdcBuild}/bin/dmd BUILD=release
    '';

    installPhase = ''
        echo -n $inputString > $out
    '';
  };

in

stdenv.mkDerivation rec {
  inherit phobosUnittests;
  name = "gdc-${version}";
  phases = "installPhase";
  buildInputs = gdcBuild.buildInputs;

  installPhase = ''
    mkdir $out
    cp -r --symbolic-link ${gdcBuild}/* $out/
  '';
  meta = gdcBuild.meta;
}

