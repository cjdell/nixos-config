# driver2 — the other Pinnacle DiB0700 drivers, patched for the PCTV 320cx

Source: `Pinnacle_TVCenterProSetup_5.4.0.3032.exe` (repo root) → WinRAR SFX payload
(`NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#unrar --command unrar x -y "[0]" /tmp/tvdrv`)
→ `Driver/<model line>/<32|64> bit/`. Only `Driver/PCTV 72e/PCTV.inf` natively claims
`USB\VID_2304&PID_022E`; everything here is a hand-edited copy that adds it.

Full write-up of the results: `docs/pctv-320cx.md` §5.6.

| file | what it is |
| --- | --- |
| `PCTV320cx-mod7700.inf` (+ `.crlf`) | `Driver/PCTV 200Xe/64 bit/PCTVDiB64.inf` + a `MOD7000_320cx.*` install section. Device Parameters copied from the 320cx sections of the stock `PCTV.inf`; **no `GpioStateTable`**; `CatalogFile` commented out. Driver: `mod7700.sys` 3.12.4.0 (2008-06-19, WHQL-signed → installs without a fight). |
| `mod7700.sys` | that driver binary (698 376 B, embedded signature valid). |
| `pctvdib64.cat` | its original catalog (unused — editing the INF invalidates it). |
| `PCTV320cx-dvb7700all{,-ts,-ts2}.inf` (+ `.crlf`) | `Driver/PCTV 340e 801e/64 bit/PCTVyu64.inf` + a 320cx section. Service renamed **`mod7700all`** and `DisplayName` changed, else `Error 1078: The name is already in use …` (both packages use the service name `mod7700`). `-ts` = for the test-signed binary, `DriverVer 10/06/2026,9.9.9.9`; `-ts2` = same but `10/07/2026,9.9.9.10` (a same-version reinstall does **not** re-copy the `.sys`). |
| `dvb7700all.sys` | that driver binary (663 040 B, **unsigned** → CM error 52 / `sc start` 577 until test-signed). |
| `PCTV320cx-dvb7700all.orig.inf` | the unmodified 340e/801e INF (reference). |

## Install recipe (Win7 x64, guest `Chris@192.168.122.59`)

```sh
./scripts/pctv-win7-ssh.sh --put pctv-linux/driver2/PCTV320cx-mod7700.inf.crlf 'C:/pctv2/PCTV320cx-mod7700.inf'
./scripts/pctv-win7-ssh.sh --put pctv-linux/driver2/mod7700.sys 'C:/pctv2/mod7700.sys'
# the install MUST run in the interactive session (ssh is non-interactive -> 0xE000023F)
./scripts/pctv-win7-ssh.sh 'schtasks /create /f /tn pctvinst /tr "C:\pctv2\inst.bat" /sc once /st 23:59 /ru "Chris-PC\Chris" /rl HIGHEST'
./scripts/pctv-win7-ssh.sh 'schtasks /run /tn pctvinst'
./scripts/pctv-win7-ssh.sh 'type C:\pctv2\instclick.log'
```

`inst.bat` = `C:\Users\Chris\instclick.exe "USB\VID_2304&PID_022E" C:\pctv2\PCTV320cx-mod7700.inf`
(`instclick.exe` = `scripts/pctv-tools/instclick.cs`, built with the guest's `csc.exe`; it also
clicks the "Windows Security → Install this driver software anyway" prompt).

## Test-signing an unsigned x64 driver for this guest

The guest has **no KB3033929**, so kernel Code Integrity rejects **SHA-256** Authenticode
(user-mode `Get-AuthenticodeSignature` still says `Valid` — do not trust it). Sign with SHA-1:

```sh
openssl req -x509 -newkey rsa:2048 -keyout k3.key -out c3.crt -days 3650 -nodes -sha1 \
  -subj "/C=GB/O=Pinnacle Test/CN=Pinnacle Test SHA1 Cert" \
  -addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning,1.3.6.1.4.1.311.10.3.22"        # MS test EKU
openssl pkcs12 -export -inkey k3.key -in c3.crt -out p3.p12 -passout pass:testpw
osslsigncode sign -pkcs12 p3.p12 -pass testpw -h sha1 -in dvb7700all.sys -out signed.sys
openssl x509 -in c3.crt -outform DER -out c3.der
```

then in the guest: `certutil -addstore -f Root C:\pctv5\c3.der`,
`bcdedit /set {current} testsigning on`, reboot (verify with `ciinfo.exe` →
`CodeIntegrityOptions = 0x3`). A `CA:TRUE` signing cert fails with *"A certificate's basic
constraint extension has not been observed"* — it must be self-signed **`CA:FALSE`**.

## Results (short)

* `mod7700.sys` 3.12.4.0 → device OK, service RUNNING, DirectShow gets **only**
  `PCTV DiB Control Filter`; no capture/tuner/xbar/audio factories (survives a reboot).
* `dvb7700all.sys` 2.3.3.28 (test-signed) → device OK, service RUNNING, **no PCTV filters at all**.
* Only the 2007 `Ltn_hyd7700pc_64.sys` builds the analog KS stack — and its crossbar never
  reaches the device (`docs/pctv-320cx.md` §5.4.3, §5.5.3).
