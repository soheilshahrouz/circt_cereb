#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "verilated.h"
#include "Vfftmain_wrapper.h"

static void tick(Vfftmain_wrapper *dut) {
  dut->i_clk = 0;
  dut->eval();
  dut->i_clk = 1;
  dut->eval();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *out_path = "build/fftmain_wrapper_outputs.txt";
  int max_outputs = 20000;
  if (argc > 1)
    max_outputs = std::atoi(argv[1]);
  if (argc > 2)
    out_path = argv[2];

  FILE *fp = std::fopen(out_path, "w");
  if (!fp) {
    std::fprintf(stderr, "error: cannot open output file '%s'\n", out_path);
    return EXIT_FAILURE;
  }

  Vfftmain_wrapper *dut = new Vfftmain_wrapper;
  dut->i_clk = 0;

  int output_count = 0;
  uint64_t cycle = 0;
  while (!Verilated::gotFinish() && output_count < max_outputs) {
    tick(dut);
    std::fprintf(fp, "%011llx %01x\n",
                 static_cast<unsigned long long>(dut->o_result & 0xFFFFFFFFFFFull),
                 dut->o_sync & 1u);
    ++output_count;
    ++cycle;
  }

  std::fclose(fp);
  delete dut;

  std::printf("Wrote %d outputs to %s (%lu cycles)\n", output_count, out_path,
              static_cast<unsigned long>(cycle));
  return EXIT_SUCCESS;
}
