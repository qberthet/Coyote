`include "log.svh"
`include "scoreboard.svh"

/* 
* This class reads input from a text file and either generates a write to the axi_ctrl stream, or it reads data from the axi_ctrl stream until certain bits match before execution continues
*/

class ctrl_simulation;
    mailbox #(trs_ctrl) mbx;
    c_axil drv;
    scoreboard scb;

    event polling_done;

    function new(mailbox #(trs_ctrl) ctrl_mbx, c_axil axi_drv, scoreboard scb);
        this.mbx = ctrl_mbx;
        this.drv = axi_drv;
        this.scb = scb;
    endfunction

    task initialize();
        drv.reset_m();
    endtask

    task run();
        trs_ctrl trs;
        logic [AXIL_DATA_BITS-1:0] read_data;

        forever begin
            mbx.get(trs);

            if (trs.is_write) begin // Write a control register
                drv.write(trs.addr, trs.data);
                `DEBUG(("Write register: %x, data: %0d", trs.addr, trs.data))
            end else begin // Read from a control register
                drv.read(trs.addr, read_data);
                if (trs.do_polling) begin
                    while (read_data != trs.data) begin
                        drv.read(trs.addr, read_data);
                    end
                    -> polling_done;
                end
                scb.writeCTRL(read_data);
                `DEBUG(("Read register: %x, data: %0d", trs.addr, read_data))
            end
        end
    endtask
endclass
