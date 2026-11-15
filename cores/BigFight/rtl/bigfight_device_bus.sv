// Big Fight board glue: two native 68000 buses to one synchronous device port.
// No matching board-level donor was found; CPU and peripheral cores stay intact.
// valid holds the backend request through arbitrary waits. The backend consumes
// req=valid&&ready on a rising edge and provides read data before that edge.
// Each transfer holds address/data/strobes through DTACK. AS may remain low
// across a TAS read/write pair; data-strobe release rearms that master.
module bigfight_device_bus (
    input logic clk, reset,
    input logic main_select, main_as_n, main_rw, main_uds_n, main_lds_n,
    input logic [23:1] main_addr,
    input logic [15:0] main_din,
    input logic sub_select, sub_as_n, sub_rw, sub_uds_n, sub_lds_n,
    input logic [23:1] sub_addr,
    input logic [15:0] sub_din,
    output logic main_dtack_n, sub_dtack_n,
    output logic [15:0] main_dout, sub_dout,
    output logic req, valid, wr, uds_n, lds_n, owner_main,
    output logic [23:1] address,
    output logic [15:0] din,
    input logic [15:0] dout,
    input logic ready
);
    logic main_done, sub_done, last_main;
    logic [15:0] main_reply_q,sub_reply_q;
    logic main_waiting, sub_waiting, grant_main;
    logic locked, locked_main;

    always_comb begin
        main_waiting = main_select && !main_as_n && !main_done &&
                       (!main_uds_n || !main_lds_n);
        sub_waiting = sub_select && !sub_as_n && !sub_done &&
                      (!sub_uds_n || !sub_lds_n);
        grant_main = locked ? locked_main :
                     main_waiting && (!sub_waiting || !last_main);
        owner_main = grant_main;
        valid = !reset && (locked ? (locked_main ? main_waiting : sub_waiting) :
                          (main_waiting || sub_waiting));
        req = valid && ready;
        address = grant_main ? main_addr : sub_addr;
        din = grant_main ? main_din : sub_din;
        wr = grant_main ? !main_rw : !sub_rw;
        uds_n = grant_main ? main_uds_n : sub_uds_n;
        lds_n = grant_main ? main_lds_n : sub_lds_n;
        main_dtack_n = !(!reset && (main_done || (req && grant_main)) && !main_as_n && (!main_uds_n || !main_lds_n));
        sub_dtack_n = !(!reset && (sub_done || (req && !grant_main)) && !sub_as_n && (!sub_uds_n || !sub_lds_n));
        // Backend data is valid before the acceptance edge. Forward the same
        // transaction to its CPU on that edge; retain the accepted data after it.
        main_dout = (req && grant_main) ? dout : main_reply_q;
        sub_dout = (req && !grant_main) ? dout : sub_reply_q;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            main_done <= 1'b0;
            sub_done <= 1'b0;
            last_main <= 1'b0;
            locked <= 1'b0;
            locked_main <= 1'b0;
            main_reply_q <= 16'hffff;
            sub_reply_q <= 16'hffff;
        end else begin
            if (valid && !ready) begin
                locked <= 1'b1;
                locked_main <= grant_main;
            end
            if (req || !valid) locked <= 1'b0;
            // A data-strobe gap ends the transfer even while AS is held.
            if (main_as_n || (main_uds_n && main_lds_n)) main_done <= 1'b0;
            if (sub_as_n || (sub_uds_n && sub_lds_n)) sub_done <= 1'b0;
            if (req) begin
                last_main <= grant_main;
                if (grant_main) begin
                    main_done <= 1'b1;
                    main_reply_q <= dout;
                end else begin
                    sub_done <= 1'b1;
                    sub_reply_q <= dout;
                end
            end
        end
    end
endmodule
