
module DualRamMix(
  input  logic        clk,
  input  logic        rst,
  output logic [31:0] out
);
  // RAM A: 16 deep x 8 bits
  logic [7:0] mem_a [0:15];

  // RAM B: 32 deep x 16 bits
  logic [15:0] mem_b [0:31];

  typedef enum logic [1:0] {
    ST_WRITE,
    ST_READ,
    ST_MIX
  } state_t;

  state_t       state;
  logic [4:0]   index;
  logic [31:0]  reg_a;
  logic [31:0]  reg_b;
  logic [7:0]   rdata_a;
  logic [15:0]  rdata_b;

  assign rdata_a = mem_a[index[3:0]];
  assign rdata_b = mem_b[index[4:0]];

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= ST_WRITE;
      index <= '0;
      reg_a <= '0;
      reg_b <= '0;
      out   <= '0;
    end else begin
      unique case (state)
        ST_WRITE: begin
          mem_a[index[3:0]] <= 8'(index * 9 + 1) ^ reg_a[7:0];
          mem_b[index[4:0]] <= 16'(index * 17 + 3 + reg_b[4:0]);
          if (index == 5'd15) begin
            state <= ST_READ;
            index <= '0;
          end else begin
            index <= index + 1'b1;
          end
        end

        ST_READ: begin
          reg_a <= reg_a + {24'b0, rdata_a} * (32'(index) + 32'd2);
          reg_b <= reg_b ^ ({16'b0, rdata_b} + 32'(index));
          if (index == 5'd15) begin
            state <= ST_MIX;
            index <= '0;
          end else begin
            index <= index + 1'b1;
          end
        end

        ST_MIX: begin
          out <= (reg_a + reg_b) ^ ((reg_a >> 3) | (reg_b << 5)) ^ (32'(index) * 32'd81);
          if (index == 5'd15) begin
            state  <= ST_WRITE;
            index  <= '0;
            reg_a  <= reg_a ^ (out >> 4);
            reg_b  <= reg_b + (out << 2);
          end else begin
            index <= index + 1'b1;
          end
        end
      endcase
    end
  end
endmodule