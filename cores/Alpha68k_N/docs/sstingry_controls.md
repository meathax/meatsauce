# Super Stingray controls and MRA — 2026-10-11

The release MRA uses **Main weapon** and **Sub weapon**, replacing the provisional Fire/Special weapon wording. These are descriptive English translations of メインウエポン and サブウエポン in the Japanese flyer review, rather than claimed transcriptions of an English instruction panel.

| MRA action | Default MiSTer button | Guest input |
| --- | --- | --- |
| Main weapon | A / joystick bit 4 | Player 1 IN0 bit 0x0010; player 2 0x1000 |
| Sub weapon | B / joystick bit 5 | Player 1 IN0 bit 0x0020; player 2 0x2000 |
| Start | Start / bit 6 | Player 1 0x0080; player 2 0x8000 |
| Coin | Select / bit 7 | Active-low MCU coin 1/2 |
| Pause | X | MiSTer pause; not a PCB action |

The gun weapon can select wide/twin/round shots. The subweapon can select mines, smoke or air support. A single fixed label such as Bomb would therefore lose part of the action's meaning. Eight-way joystick movement and two action buttons agree with MAME 0.289.

Sources inspected:

- [Japanese flyer review, 2020-11-23](https://maedahiroyuki.com/20201123-%E3%82%B9%E3%83%BC%E3%83%91%E3%83%BC%E3%83%BB%E3%82%B9%E3%83%86%E3%82%A3%E3%83%B3%E3%82%B0%E3%83%AC%E3%82%A4/): identifies the two weapon roles and selectable weapons. This is a secondary explanation alongside the historical flyer, not a claim that printed labels were transcribed.
- [Original instruction/information archive index](https://t-8100.com/newpage5.html): the Super Stingray section lists original instruction and information scans.
- [Original Japanese advertisement flyer listing](https://gamesdb.launchbox-app.com/games/images/39361-super-stingray): Advertisement Flyer Front, Japan, link 21.
- Local MAME 0.289 `src/mame/alpha/alpha68k_n.cpp:574–626`: player button 1/2 masks, start/coin inputs and all DIP values. Local core `Alpha68k_N.sv:146–147,183` maps the corresponding physical buttons without changing RTL.

The archive images could not be visually opened in this session (web cache miss; browser transport unavailable). Literal printed-panel wording and primary-panel confirmation of the weapon order remain unqualified. The two role names are supported by the Japanese review; the wiring order retains the existing MRA/MAME button order.

`releases/Super Stingray (Japan).mra` uses RBF Alpha68k_N, set sstingry, MAME 0289, loader profile 2, the audited CRC/layout, the MAME DIP default 0x01, and the existing 148-byte high-score ranges. Its about note retains incomplete simulation/gameplay/input/cocktail/earned-score/hardware qualification. Providing this loader does not qualify the current RBF for Super Stingray.

Regenerate only this artifact with `python scripts/make_feature_mras.py --set sstingry`. The scoped receipt is `research/feature_mra_validation_sstingry.json`; Kyros/Japan MRAs and their packed ROMs are not regenerated.
