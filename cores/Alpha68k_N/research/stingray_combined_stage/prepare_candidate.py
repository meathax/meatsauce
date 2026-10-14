"""Prepare a private P6 overlay; never edit canonical sources or launch a build."""
from pathlib import Path
import ast
import csv
import difflib
import hashlib
import json
import subprocess

HERE=Path(__file__).resolve().parent
CANON=Path("D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N")
OLD=HERE.parents[1]
MAME=Path("D:/Arcade/AI/mame289/src/mame/alpha/alpha68k_n.cpp")
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()


def replace_once(text,old,new):
    assert text.count(old)==1,(old[:100],text.count(old))
    return text.replace(old,new,1)


def main():
    if (HERE / "integration_contract.json").exists():
        raise SystemExit("Private candidate already prepared; preserve pins and patches.")
    paths=["rtl/alpha68kn_board.sv","rtl/alpha68kn_system.sv","rtl/alpha68kn_mcu.sv",
           "rtl/vendor/fx68k/fx68k.sv","rtl/vendor/t48/t48_core.v","rtl/vendor/t48/SOURCE.json",
           "rtl/vendor/t48/LICENSE.upstream","files.qip","sim/system_main.cpp","sim/build_system.sh",
           "rom_layout.json","board_profiles.json","docs/STINGRAY_MCU_INTERFACE.md"]
    pins={p:H(CANON / p) for p in paths}
    assert pins["rtl/alpha68kn_board.sv"].startswith("adff9fcb8c7018e8")
    assert pins["sim/system_main.cpp"].startswith("f8d02e905e939246")
    assert pins["rtl/alpha68kn_mcu.sv"].startswith("623e1c4c2ca31930")
    assert H(MAME)=="5f9884076ea1b5c02d2169a58de5425ae5475a13a4f1438abae2e2b9f0fdab7d"
    try:
        git=subprocess.run(["git","-C",str(CANON),"rev-parse","HEAD"],capture_output=True,text=True,check=True)
        revision=git.stdout.strip()
    except Exception as e:
        revision="Unavailable: "+type(e).__name__
    originals={p:(CANON / p).read_text() for p in ["rtl/alpha68kn_board.sv","files.qip","sim/system_main.cpp","sim/build_system.sh"]}
    board=originals["rtl/alpha68kn_board.sv"]
    board=replace_once(board,"    always @(posedge clk) paused<=pause_game && !held_reset;",
        """    wire is_stingray=profile==8'd2;
    // Existing wrapper P2 observation and board write are registered stages.
    // Hold the HS borrow through their pre-pause drain; guard the port directly too.
    logic [1:0] sting_pause_drain=0;
    always @(posedge clk) begin
        if(held_reset || !is_stingray || !pause_game) sting_pause_drain<=0;
        else if(sting_pause_drain!=3) sting_pause_drain<=sting_pause_drain+1'b1;
        paused<=pause_game && !held_reset &&
            (!is_stingray || (sting_pause_drain==3 && !sting_mcu_shared_write));
    end""")
    board=replace_once(board,"    wire ce_z80 = zphase == 0;",
        """    logic [25:0] sting_z_fraction=0;
    wire [26:0] sting_z_sum={1'b0,sting_z_fraction}+27'd3579545;
    wire ce_z80 = is_stingray ? sting_z_sum>=27'd48000000 : zphase==0;
    always @(posedge clk) begin
        if(held_reset || !is_stingray) sting_z_fraction<=0;
        else if(!pause_game) begin
            if(sting_z_sum>=27'd48000000) sting_z_fraction<=sting_z_sum-27'd48000000;
            else sting_z_fraction<=sting_z_sum[25:0];
        end
    end""")
    board=replace_once(board,"    fx68k maincpu (",
        """    wire [11:0] sting_mcu_program_addr;
    logic [7:0] sting_mcu_program_q=0;
    wire sting_mcu_main_halt,sting_mcu_irq2,sting_mcu_shared_write,sting_mcu_flip;
    wire sting_mcu_command_valid,sting_mcu_bus_event,sting_mcu_control_event;
    wire [7:0] sting_mcu_shared_addr,sting_mcu_shared_data,sting_mcu_bus,sting_mcu_control;
    wire [31:0] sting_mcu_oscillator_ticks,sting_mcu_core_ticks;
    // fx68k HALTn is documented as single-step. Drain the accepted AS cycle,
    // then freeze the existing phase/enables at AS-high. This P6 boundary
    // requires a coupled-CPU trace before physical/MAME timing qualification.
    wire sting_main_pause=is_stingray && sting_mcu_main_halt && mas_n;
    always @(posedge clk) sting_mcu_program_q<=mcu_rom[sting_mcu_program_addr];
    alpha68kn_mcu sting_mcu (
        .clk(clk),.reset(held_reset || !is_stingray),.pause_game(pause_game),
        .program_addr(sting_mcu_program_addr),.program_data(sting_mcu_program_q),
        .command_valid(sting_mcu_command_valid),.command_read(mrw_n),
        .command_addr(ma[8:1]),.command_data(mdout[7:0]),.coins_n(coins_n),
        .main_halt(sting_mcu_main_halt),.irq2(sting_mcu_irq2),
        .shared_write(sting_mcu_shared_write),.shared_addr(sting_mcu_shared_addr),
        .shared_data(sting_mcu_shared_data),.flip(sting_mcu_flip),
        .bus_data(sting_mcu_bus),.control(sting_mcu_control),
        .bus_event(sting_mcu_bus_event),.control_event(sting_mcu_control_event),
        .oscillator_ticks(sting_mcu_oscillator_ticks),.core_ticks(sting_mcu_core_ticks)
    );
    fx68k maincpu (""")
    board=replace_once(board,".enPhi1(cpu_phase==0 && !pause_game), .enPhi2(cpu_phase==4 && !pause_game)",
                       ".enPhi1(cpu_phase==0 && !pause_game && !sting_main_pause), .enPhi2(cpu_phase==4 && !pause_game && !sting_main_pause)")
    board=replace_once(board,"sound_rom_selected_q <= !sound_io_rd && za < 'hc000;",
                       "sound_rom_selected_q <= !sound_io_rd && za < (is_stingray ? 16'h8000 : 16'hc000);")
    board=replace_once(board,"else if (za >= 'hc000 && za < 'hc800) sound_nonrom_q <= sound_ram[za[10:0]];\n        else if (za == 'he000) sound_nonrom_q <= sound_latch;",
        """else if ((is_stingray && za >= 'h8000 && za < 'h8800) ||
                 (!is_stingray && za >= 'hc000 && za < 'hc800)) sound_nonrom_q <= sound_ram[za[10:0]];
        else if (za == (is_stingray ? 16'hc100 : 16'he000)) sound_nonrom_q <= sound_latch;""")
    board=replace_once(board,"    wire ram_bus_service=!held_reset && !pause_game && !mas_n && !bus_done",
        """    // MCU control writes preserve the shared word's high byte. A real MCU
    // write owns the single byte-bank write port for this master edge.
    wire sting_mcu_work_service=is_stingray && !held_reset && sting_mcu_shared_write;
    wire ram_bus_service=!held_reset && !pause_game && !mas_n && !bus_done""")
    board=replace_once(board,"&& (iack || maddr>=24'h020000 || main_rom_addr_q==ma[16:1]);",
        """&& (iack || maddr>=24'h020000 || main_rom_addr_q==ma[16:1])
        && (!sting_mcu_work_service || iack || maddr<24'h020000 || maddr>=24'h021000);
    assign sting_mcu_command_valid=is_stingray && ram_bus_service && !iack &&
        maddr>=24'h080000 && maddr<24'h080200 && !mlds_n;""")
    board=replace_once(board,"    // Exact accepted edge; no CPU enable, AS, byte-strobe or DTACK change.",
                       "    // Kyros accepted edge retained; profile2 work collision defers DTACK below.")
    board=replace_once(board,"wire hs_work_service=!held_reset && pause_game && paused && hs_access",
                       "wire hs_work_service=!held_reset && pause_game && paused && hs_access && !sting_mcu_work_service")
    board=replace_once(board,"wire hle_service=ram_bus_service && !iack", "wire hle_service=!is_stingray && ram_bus_service && !iack")
    board=replace_once(board,"wire [10:0] work_port_addr=hs_work_service ? hs_addr[11:1] :",
                       "wire [10:0] work_port_addr=sting_mcu_work_service ? {3'd0,sting_mcu_shared_addr} : hs_work_service ? hs_addr[11:1] :")
    board=replace_once(board,"wire work_write_lo=(hs_work_service && hs_write && hs_addr[0])",
                       "wire work_write_lo=sting_mcu_work_service || (hs_work_service && hs_write && hs_addr[0])")
    board=replace_once(board,"wire [7:0] work_data_lo=hs_work_service ? hs_data_in : cpu_work_service ? mdout[7:0] :",
                       "wire [7:0] work_data_lo=sting_mcu_work_service ? sting_mcu_shared_data : hs_work_service ? hs_data_in : cpu_work_service ? mdout[7:0] :")
    board=replace_once(board,"if(!pause_game) cpu_phase<=cpu_phase+1'b1;", "if(!pause_game && !sting_main_pause) cpu_phase<=cpu_phase+1'b1;")
    board=replace_once(board,"            if (irq2_count==799999) begin irq2_count<=0;irq2<=1; end\n            else irq2_count<=irq2_count+1'b1;",
        """            if (!is_stingray) begin
                if (irq2_count==799999) begin irq2_count<=0;irq2<=1; end
                else irq2_count<=irq2_count+1'b1;
            end""")
    board=replace_once(board,"            else if (!bus_done && (iack || !muds_n || !mlds_n)\n                && (iack || maddr>=24'h020000 || main_rom_addr_q==ma[16:1])) begin",
                       "            else if (ram_bus_service) begin")
    board=replace_once(board,"                    mdin_other<=0;mcu_transactions<=mcu_transactions+1'b1;\n                    if (!mrw_n) begin",
        """                    mdin_other<=is_stingray ? 16'hff00 : 16'd0;
                    mcu_transactions<=mcu_transactions+1'b1;
                    if(is_stingray) begin
                        // Actual wrapper consumes the low-byte command pulse.
                        // Upper-only accesses have no MCU side effect (umask00ff).
                    end else if (!mrw_n) begin""")
    board=replace_once(board,"if (za >= 'hc000 && za < 'hc800) sound_ram[za[10:0]]<=zdout;\n                    if (za=='he002) begin sound_latch<=0;sound_latch_pending<=0; end\n                    if (za=='he004) begin dac<=zdout;sound_dac_wr<=1; end",
        """if ((is_stingray && za >= 'h8000 && za < 'h8800) ||
                        (!is_stingray && za >= 'hc000 && za < 'hc800)) sound_ram[za[10:0]]<=zdout;
                    if (za==(is_stingray ? 16'hc102 : 16'he002)) begin sound_latch<=0;sound_latch_pending<=0; end
                    if (za==(is_stingray ? 16'hc104 : 16'he004)) begin dac<=zdout;sound_dac_wr<=1; end""")
    board=replace_once(board,"            end\n            end\n        end\n    end\nendmodule",
        """            end
            end
            // Set wins over same-edge IACK: do not lose a fresh firmware IRQ2.
            if(is_stingray && sting_mcu_irq2) irq2<=1;
            if(is_stingray && sting_mcu_control_event) flip<=sting_mcu_flip;
        end
    end
endmodule""")
    qip=originals["files.qip"]+"\nset_global_assignment -name SYSTEMVERILOG_FILE rtl/alpha68kn_mcu.sv\nset_global_assignment -name VERILOG_FILE rtl/vendor/t48/t48_core.v\n"
    host=replace_once(originals["sim/system_main.cpp"],"bytes[5]>1)","bytes[5]>2)")
    host=replace_once(host,'"Kyros/Japan payload required; Stingray CPU/MCU not implemented"','"Alpha68k_N profile0/1/2 payload required"')
    host=replace_once(host,"    if(warm_reset_after<requested && ports.empty())",
        """    // Profile2 must use actual recorded MAME controls/DIPs/coins, including
    // attract. Do not reuse the Kyros default DIP or scripted gameplay input.
    if(bytes[5]==2 && ports.empty())
        throw std::runtime_error("Stingray requires source-qualified --inputs port trace");
    if(warm_reset_after<requested && ports.empty())""")
    build=originals["sim/build_system.sh"]
    build=replace_once(build,"    sim/system_main.cpp sim/sdram_model.h > sim/build/system_inputs.sha256",
                       "    rtl/vendor/t48/t48_core.v sim/system_main.cpp sim/sdram_model.h > sim/build/system_inputs.sha256")
    build=replace_once(build,"    rtl/alpha68kn_gfxmem.sv rtl/alpha68kn_system.sv rtl/alpha68kn_audio.sv \\",
                       "    rtl/alpha68kn_gfxmem.sv rtl/alpha68kn_system.sv rtl/alpha68kn_audio.sv rtl/alpha68kn_mcu.sv \\")
    build=replace_once(build,"    sim/system_main.cpp sim/sdram_model.h \"$build_root/\"",
                       "    rtl/vendor/t48/t48_core.v sim/system_main.cpp sim/sdram_model.h \"$build_root/\"")
    build=replace_once(build,"    alpha68kn_system.sv alpha68kn_audio.sv alpha68kn_soundchips.sv alpha68kn_mixer.sv \\",
                       "    alpha68kn_system.sv alpha68kn_audio.sv alpha68kn_soundchips.sv alpha68kn_mixer.sv alpha68kn_mcu.sv \\")
    changes={"rtl/alpha68kn_board.sv":board,"files.qip":qip,"sim/system_main.cpp":host,"sim/build_system.sh":build}
    patch=[]
    overlay=[]
    for rel,text in changes.items():
        dest=HERE / "candidate" / rel;dest.parent.mkdir(parents=True,exist_ok=True)
        dest.write_text(text,encoding="utf8",newline="\n")
        patch.extend(difflib.unified_diff(originals[rel].splitlines(True),text.splitlines(True),fromfile="a/"+rel,tofile="b/"+rel,n=3))
        overlay.append({"path":str(dest),"target":rel,"base_sha256":pins[rel],"candidate_sha256":H(dest)})
    pp=HERE / "stingray_integration.patch";pp.write_text("".join(patch),encoding="utf8",newline="\n")
    layout=json.loads((CANON / "rom_layout.json").read_text());profile=layout["sets"]["sstingry"]
    download=CANON / profile["path"]
    assert H(download)==profile["sha256"]
    payload=download.read_bytes();assert len(payload)==655360 and payload[:4]==b"A68N" and payload[5]==2
    mcu=next(x for x in profile["regions"] if x["name"]=="mcu")
    firmware=CANON / mcu["source_path"]
    assert H(firmware)==mcu["sha256"] and len(firmware.read_bytes())==1024
    assert payload[layout["slots"]["mcu"]["base"]:layout["slots"]["mcu"]["base"]+1024]==firmware.read_bytes()
    retained=[]
    for root in [CANON,OLD]:
        for mode in ["attract","gameplay"]:
            p=root / "sim/captures/sstingry" / mode / "frame_states.csv"
            if p.exists():
                with p.open() as f:reader=csv.DictReader(f);cols=reader.fieldnames;first=next(reader,None)
                retained.append({"path":str(p),"sha256":H(p),"columns":cols,"initial_ports":{k:first.get(k) for k in ["in0","in1","in2"]} if first else None,
                                 "qualified_for_replay":False,"limit":"Requires actual recording job/exe/ROM/source and full sequence qualification before launch"})
    checks={"canonical_source_bytes_unchanged":all(H(CANON / p)==value for p,value in pins.items()),
            "all4_overlay_sources_written":len(overlay)==4,"profile2_download_header_and_hash":True,"clean1024_firmware_hash_and_payload_slot":True,
            "MCU_input_ports_all_explicit":all(s in board for s in [".clk(clk),.reset(held_reset || !is_stingray),.pause_game(pause_game)",".program_data(sting_mcu_program_q)",".command_valid(sting_mcu_command_valid)",".coins_n(coins_n)"]),
            "MCU_HALTN_single_step_input_not_misused":".HALTn(1'b1)" in board,
            "Kyros_HLE_disabled_only_for_profile2":"wire hle_service=!is_stingray" in board,
            "no_strip_storage_or_renderer_port_change":originals["rtl/alpha68kn_board.sv"].split("    // Two SDP copies",1)[1].split("    always_ff @(posedge clk)",1)[0]==board.split("    // Two SDP copies",1)[1].split("    always_ff @(posedge clk)",1)[0],
            "MCU_closure_added_to_QIP_and_native_copy": "rtl/vendor/t48/t48_core.v" in qip and "rtl/vendor/t48/t48_core.v" in build and "alpha68kn_mcu.sv" in build,
            "profile2_native_requires_observed_ports":'if(bytes[5]==2 && ports.empty())' in host,
            "pause_MCUpulse_excludes_HS_port":"hs_access && !sting_mcu_work_service" in board,
             "profile2_pause_drain_initialized":"logic [1:0] sting_pause_drain=0;" in board,
             "generator_python_syntax":True}
    ast.parse(Path(__file__).read_text());assert all(checks.values()),checks
    contract={"schema":"sstingray_combined_private_candidate_v2","canonical_root":str(CANON),"canonical_revision":revision,
        "source_pins":pins,"MAME_driver":{"path":str(MAME),"sha256":H(MAME),"lines":"301-358 command/control;376-385 main;421-429 sound;735-772 clock/IRQ/audio"},
        "overlay":overlay,"patch_path":str(pp),"patch_sha256":H(pp),"helper_sha256":H(Path(__file__)),"static_checks":checks,
        "loader":{"download_path":str(download),"sha256":H(download),"bytes":len(payload),"profile":2,"transport":"First byteD7:0; main_rom swaps into big-endian68000 words; MCU bytes stayraw",
                  "mcu_base":layout["slots"]["mcu"]["base"],"mcu_capacity":4096,"firmware_path":str(firmware),"firmware_sha256":H(firmware),"firmware_bytes":1024,"MCU_program_read":"One synchronous8bit read from existing mcu_rom; external program space remains wrapper-unmapped"},
        "clocks":{"master_hz":48000000,"main_68000_hz":6000000,"sound_z80_hz":3579545,"sound_method":"Fractional integer sum+3579545 against48000000, frozen on pause/reset", "MCU_xtal_hz":9263750,"MCU_method":"Reuse unchanged wrapper oscillator CE and donor xtal3 five-state execution; no extra divide15 or generated clock", "sound_chips_hz":2000000,"NMI_hz":4000},
        "command_contract":{"range":"080000..0801ff","byte_lane":"LDS low only, MAMEumask00ff","address":"word index ma[8:1]","read_data_low":0,"write_data":"mdout[7:0]","read_mode":"mrw_n","trigger":"Actual accepted board transaction, no scripted MCU response"},
        "work_RAM_arbitration":{"storage":"Existing split full-byte2048wordbanks and externalword22; no second RAM write port or new storagecopy",
            "priority":"Actual wrapper shared_write owns this edge; colliding profile2CPU work transaction waits until following edge. Other CPU regions retain acceptance.",
            "MCU_write":"Low byte only at zero-extended8bit wordaddress; high byte retained. Word22 routes externalregister; word29high shadow unaffected by lowwrites.",
            "pause_hiscore":"Wrapper clock enables stop on pause; three master edges hold HS borrow while registered control/write drains. MCU pulse directly excludes HS port even if paused was already asserted. HS and CPU OLD_DATA/prior response hold remain existing paths; actual pause-pipeline timing still unqualified.",
            "physical_priority_verified":False,"paired_MAME_order_verified":False},
        "interrupts":{"IRQ1":"Existingvblank HOLD/IACK unchanged","IRQ2":"Firmwarepulse HOLD untilIACK; no periodicKyros60Hz IRQ2 inprofile2; freshrequest wins same-edgeIACK",
            "HALT":"HALTn is single-step in pinnedfx68k. Privatecandidate drains AS-low command cycle then freezes existingphase/enables whilemcu_main_halt andAS-high. This is a candidate boundary, not physical or MAME cutoff proof.",
            "flip":"Actual MCU control_event updates boardflip, one additional board sampling edge; KyrosHLEflip unchanged"},
        "sound_map":"Profile2ROM0000..7fff,RAM8000..87ff,latchc100,clearc102,DACc104; Kyrosranges unchanged. Existing I/Ochips/mixerprofile retained.",
        "harness":{"host_target":"sim/system_main.cpp","accepts_profile2":True,"requires_actual_port_trace":True,"retained_input_candidates":retained,
            "prospective_command":"wsl.exe -d Ubuntu --cd CANONICAL_OR_REVIEWED_PRIVATE_ROOT --exec ./sim/build/alpha68kn_system_sim roms/sstingry/download.bin FIELDS OUTPUT attract --inputs QUALIFIED_STINGRAY_frame_states.csv",
            "launch_authorized_by_this_task":False,"note":"No guessedKyrosDIP, event-derivedsyntheticstate, or CPU/RAM seeding; same realCPU+renderer+SDRAM model harness"},
        "open_assumptions":["CoupledCPU HALT/DTACK recognition and AS-high freeze boundary need observed pairedMAME handshake; HALTn annotation alone does not qualify timing.",
            "Shared-write collision priority/deferredDTACK is private scheduling, not measured PCB arbitration. Need command/release/sharedwrite/IRQ2 trace before integrationacceptance.",
            "MCU wrapper output observation plus board sampling adds a boardedge; command/P2/BUS ordering and repeated identicalwrites need paired reference qualification.",
            "Pause-drain depth follows the visible registered wrapper/board pipeline but needs coupled capture, including a pre-pause control strobe; no physical delay is claimed.",
             "High command-read byteff is a candidate unmappedlane value; lowerbyte0 is sourced. Verify actual word/high-only accesses in the retained MAME trace.",
            "MCU9.263750MHz physicalaccuracy remainsB10unqualified; candidate followsMAME. Existing B07firmware/probe does not prove full gameplay.",
            "Retained Stingray input/reference capture schema/ROM/exe/epoch must be qualified before use. No combinedbuildorStingraysimulation hasrun.",
            "Full soundeffects/PCM, palette/wrap/playercontrols, whole fittedresources/timing and Kyrosregression remainpending; no sourcecorrection is claimed from this stage."],
        "acceptance_next":["Review thispatch/contract and baseline currentKyros simulation+fit; import only as a coherentparentphase.",
            "Qualify one retained Stingray MAMEinput+ROM+source record; observe command/lowbyte/lane/control/HALT/IRQ2 boundaries.",
            "Only afterparentauthorization buildone source-pinned combined candidate; use short authentic boot/handshake to findfirstdivergence, thenattract/coin/start/gameplay on sameexe.",
            "Run affectedKyros shortregression once ifsharedRTLchanges; inspectM10Kinference thenfullQuartusFastmap/fit/STA withoutassembly; enforceallstrictcaps."],
        "combined_build_pass":False,"combined_simulation_pass":False,"paired_MAME_pass":False,"physical_fidelity_pass":False,"resource_timing_pass":False,"production_edited":False}
    (HERE / "integration_contract.json").write_text(json.dumps(contract,indent=2)+"\n")
    (HERE / "integration_contract.md").write_text("# Private Super Stingray P6 candidate\n\nThe overlay adds the already proven real8748 wrapper and T48 closure to profile2, with the existing655360-byte loader/profile header and clean1024-byte d8748 firmware. All canonical sources remain untouched. The privatepatch changes only board, QIP, nativehost profile guard and nativebuild source closure; no build or simulation is launched.\n\nAll logic uses the48MHz master. Z80 uses fractional3579545Hz enables; MCU uses the unchanged9263750Hz wrapper oscillator and donor internal divide3/five-state execution. No extra divide15 or generated CPU clock is introduced. The MCU command lane is LDS only at080000..0801ff; wordindex/data/readmode are latched on actual accepted transactions.\n\nA real MCU shared_write owns the existing low-byte RAM write port for that edge. A colliding profile2CPU work transfer waits; MCUword22 routes its externalregister, all highbytes and word29highshadow remain intact. Pause holds the HS borrow for three master edges while the registered MCU control/write pipeline drains; a shared_write also directly excludes HS service. This ordering remains to be observed in the coupled run. Physical collision priority remains unqualified.\n\nFirmware IRQ2 is held untilIACK and replaces periodicKyrosIRQ2 for profile2. Freshrequest wins a sameedgeIACK; that boundary needs reference proof. MCUcontrol drivesflip. The pinnedfx68k HALTn is labelled single-step, so the candidate keeps it high and drains the acceptedAS cycle before freezing the existingphase/enables atAS-high while MCUHALT remainsasserted. This candidate HALT/DTACK cutoff needs a coupledCPU/pairedMAME trace and is not declaredcorrect.\n\nProfile2sound uses ROM0000..7fff,RAM8000..87ff,latchc100,clearc102,DACc104. Existing nativeI/Ochips, mixerprofile, renderer and physicalstripread remain intact. Nativehost permitsprofile2 only with actualrecordedMAME controls/DIPs/coins; no KyrosdefaultDIP or syntheticgameplay fallback is allowed. Retainedreferencemetadata must be qualified before running.\n\nStaticloader/sourcepins and patchchecks pass only; there is no HDLcompile, realStingrayCPU run, fullgraphics/audio, fit/timing or physicalMCU pass. Review integration_contract.json for exactpins, all open ordering assumptions and the minimum next acceptance steps.\n")
    checks_path=HERE / "static_preparation.json"
    checks_path.write_text(json.dumps({"checks":checks,"pass":all(checks.values()),"canonical_revision":revision,"contract_sha256":H(HERE / "integration_contract.json"),
                                       "HDL_compiled":False,"simulation_launched":False,"production_edited":False},indent=2)+"\n")
    owned=[Path(__file__),HERE / "finalize_pause_guard.py",pp,HERE / "integration_contract.json",HERE / "integration_contract.md",checks_path]+[Path(x["path"]) for x in overlay]
    manifest={"schema":"sstingray_private_prepare_import_v1","entries":[{"source":str(p),"destination":"research/stingray_combined_stage/"+p.relative_to(HERE).as_posix(),"sha256":H(p)} for p in owned],
              "production_patch_to_apply_only_after_parent_review":str(pp),"canonical_sources_unchanged":checks["canonical_source_bytes_unchanged"],"no_build_or_replay":True}
    mp=HERE / "import_manifest.json";mp.write_text(json.dumps(manifest,indent=2)+"\n")
    assert all(H(CANON / p)==value for p,value in pins.items())
    print(json.dumps({"canonical_revision":revision,"static_checks":checks,"patch_sha256":H(pp),"contract_sha256":H(HERE / "integration_contract.json"),
                      "manifest":str(mp),"manifest_sha256":H(mp),"entries":len(owned),"retained_input_candidates":retained,"no_build_or_replay":True}))


if __name__=="__main__":main()
