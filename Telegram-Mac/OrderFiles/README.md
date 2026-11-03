# Launch order file

`Telegram.order` lists, in order, the functions of the app executable (`Nanogram`) that run while the app
launches. Release builds pass it to the linker (`ORDER_FILE`, set through `NANOGRAM_ORDER_FILE` by
`tools/dev/nanogram/release.py` and `nanogram/Nanogram.xcconfig`) so those functions sit next to each other at
the start of `__TEXT,__text`: a cold launch then faults in fewer pages of the binary. Debug builds ignore it.
Names the linker cannot find are ignored, so a stale list never breaks the build; it only lays out less of the
launch.

| File | Source |
| --- | --- |
| `signed-in.order` | Launches of the owner's signed-in release app up to the chat list (the main source) |
| `signed-out.order` | Isolated launches of the archived app to the login screen (no account needed) |
| `Telegram.order` | `signed-in.order`, then the `signed-out.order` symbols it lacks (login-only code); the generator rewrites it after every run |

The lists come from sampling launches with Instruments ("App Launch"), so they cover the hot path of launch
rather than every function. Samples from the traced binary are merged across runs by time since launch, with
callers before callees, and mapped to linker symbols with the archive's dSYM.

Regenerate after large changes to the launch path, from the Release archive of the build being traced:

```sh
# signed-in (main source): the installed app must be that archive's build, signed in, and not running
python3 tools/dev/orderfile.py --signed-in --app /Applications/Nanogram.app \
    --archive build-output/direct/<build>/Nanogram.xcarchive --runs 5

# signed-out baseline: leaves a running Nanogram and its data alone
python3 tools/dev/orderfile.py --archive build-output/direct/<build>/Nanogram.xcarchive --runs 3
```

A signed-in run quits the app and relaunches it for each trace (8 s each, then a normal quit). It opens no
chats and keeps only the app's own samples. Each trace writes 1–3 GB of raw kernel trace to the user temp
folder. The generator deletes those files after every run and starts no run below 18 GB free
(`--min-free-gb`), so a build running beside it keeps at least 15 GB.

## Checking a Release build

The 13.1.2 Release archive is the first build linked with this list. Check it from the archive's dSYM (symbol
addresses there are the final layout, so no extra build setting is needed):

```sh
python3 tools/dev/orderfile.py --check \
    build-output/direct/<build>/Nanogram.xcarchive/dSYMs/Nanogram.app.dSYM/Contents/Resources/DWARF/Nanogram
```

It prints how many listed functions the binary has, how many of them are the first functions of `__text` and how
many follow list order, and exits 1 unless both are at least 90%. A link without the list fails the check: the
13.1.1 archive (202611032053) gives `leading __text: 7 of 490; in list order: 255 of 490`.

The same check reads an ld link map. Build with `LD_GENERATE_MAP_FILE=YES` and pass the map
(`$(TARGET_TEMP_DIR)/$(PRODUCT_NAME)-LinkMap-normal-arm64.txt` by default) to `--check`. Before checking either one,
confirm that the link used the list: `(cd tools/dev && python3 -m nanogram.release settings)` must print
`NANOGRAM_ORDER_FILE=…/Telegram-Mac/OrderFiles/Telegram.order`.

Today `Telegram.order` holds only the signed-out list (1,531 symbols, 490 functions from five isolated launches of
13.1.1). Record the signed-in list with the command above once the installed app is the archive's build. The
generator then rewrites `Telegram.order` with the signed-in order first.
