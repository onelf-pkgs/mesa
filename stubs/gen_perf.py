"""Stand-in for Mesa's src/intel/perf/gen_perf.py.

The real generator turns the oa-*.xml metric sets into about 5 MB of
tables for GL_INTEL_performance_query. This one writes the same API, one
`intel_oa_register_queries_<platform>` per metric set, as functions that
register nothing, so the Intel drivers build unchanged and the extension
reports no counters.
"""

import argparse
import os

parser = argparse.ArgumentParser()
parser.add_argument("--header", required=True)
parser.add_argument("--code", required=True)
parser.add_argument("xml_files", nargs="+")
args = parser.parse_args()

platforms = [
    os.path.basename(path)[len("oa-"):-len(".xml")]
    for path in args.xml_files
    if os.path.basename(path).startswith("oa-")
]

with open(args.header, "w") as header:
    header.write("#pragma once\n\nstruct intel_perf_config;\n\n")
    for platform in platforms:
        header.write(f"void intel_oa_register_queries_{platform}(struct intel_perf_config *perf);\n")

with open(args.code, "w") as code:
    code.write('#include "perf/intel_perf_metrics.h"\n\n')
    for platform in platforms:
        code.write(
            f"void intel_oa_register_queries_{platform}(struct intel_perf_config *perf)\n"
            "{\n   (void)perf;\n}\n\n"
        )
