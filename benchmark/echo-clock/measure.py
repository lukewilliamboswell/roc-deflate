#!/usr/bin/env python3
"""Build/run embedded-input C and Roc drivers, preserving every timing sample."""
import argparse, csv, hashlib, json, os, pathlib, shutil, statistics, subprocess, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
PLATFORM = ROOT / 'benchmark/echo-clock'
FILES = 'dickens mozilla mr nci ooffice osdb reymont samba sao webster x-ray xml'.split()

def run(cmd, **kw):
    return subprocess.run([str(x) for x in cmd], check=True, **kw)

def digest(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()

def build(args):
    run([PLATFORM / 'build.sh'])
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    mi = PLATFORM / '.build/mimalloc-8c532c32c3c96e5ba1f2283e032f69ead8add00f'
    target = 'arm64mac' if os.uname().machine == 'arm64' else 'x64mac'
    libs = list((args.libdeflate / 'lib').glob('*.c')) + list((args.libdeflate / 'lib').glob('*/*.c'))
    for file in args.files:
        directory = out / file
        directory.mkdir(exist_ok=True)
        data = (args.corpus / file).resolve()
        # Both engines use the exact file bytes embedded in the executable.
        asm = '.section __TEXT,__const\n.p2align 4\n.globl _corpus_input\n_corpus_input:\n.incbin ' + json.dumps(str(data)) + '\n'
        (directory / 'input.s').write_text(asm)
        source = (ROOT / 'benchmark/cbench.c').read_text()
        start, end = source.index('static unsigned char *slurp'), source.index('\nint main(')
        source = source[:start] + f'''extern unsigned char corpus_input[];
static unsigned char *slurp(const char *path, size_t *len) {{
    (void)path; *len = {data.stat().st_size}; return corpus_input;
}}
''' + source[end:]
        source = '#include "mimalloc.h"\n' + source
        source = source.replace('malloc(', 'mi_malloc(')
        source = source.replace('    struct libdeflate_compressor *c =', '    libdeflate_set_memory_allocator(mi_malloc, mi_free);\n    struct libdeflate_compressor *c =')
        source = source.replace('    size_t sz = libdeflate_deflate_compress', '    struct timespec warm_started, warm_now;\n    clock_gettime(CLOCK_MONOTONIC, &warm_started);\n    size_t sz = libdeflate_deflate_compress')
        source = source.replace('    long long best = 0;', '''    unsigned char *expected = mi_malloc(sz);
    size_t expected_len = sz;
    memcpy(expected, out, sz);
    clock_gettime(CLOCK_MONOTONIC, &warm_now);
    while ((warm_now.tv_sec - warm_started.tv_sec) * 1000000000LL + warm_now.tv_nsec - warm_started.tv_nsec < 200000000LL) {
        sz = libdeflate_deflate_compress(c, in, n, out, cap);
        if (sz != expected_len || memcmp(out, expected, sz)) { fprintf(stderr, "warmup output changed\\n"); return 6; }
        clock_gettime(CLOCK_MONOTONIC, &warm_now);
    }
    long long best = 0;''')
        source = source.replace('        if (i == 0 || ns < best) best = ns;', '''        if (sz != expected_len || memcmp(out, expected, sz)) { fprintf(stderr, "output changed\\n"); return 6; }
        printf("rep\\t%d\\t%d\\t%lld\\t%zu\\n", level, i, ns, sz);
        if (i == 0 || ns < best) best = ns;''')
        source = source.replace('    return 0;\n}', '''    libdeflate_free_compressor(c);
    libdeflate_free_decompressor(d);
    mi_free(out); mi_free(back); mi_free(expected);
    return 0;
}''')
        (directory / 'cbench.c').write_text(source)
        run(['cc', '-O3', '-DMI_STATIC_LIB', '-I', mi / 'include', '-I', args.libdeflate,
             directory / 'cbench.c', directory / 'input.s', *libs, PLATFORM / f'targets/{target}/mimalloc.o', '-o', directory / 'cbench'])
        stage = PLATFORM / ".build/measurement" / file
        stage.mkdir(parents=True, exist_ok=True)
        imports, cases = [], []
        for level in args.levels:
            ref = directory / f'level-{level}.deflate'
            run([directory / 'cbench', 'embedded', level, 1, ref], stdout=subprocess.DEVNULL)
            shutil.copyfile(ref, stage / ref.name)
            imports.append(f'import "{ref.name}" as ref{level} : List(U8)')
            cases.append(f'{{ level: {level}, expected: ref{level} }}')
        rel = lambda p: json.dumps(os.path.relpath(p, stage))
        (stage / 'app.roc').write_text('app [main!] {\n' +
            f' pf: platform {rel(PLATFORM / "main.roc")},\n deflate: {rel(ROOT / "package/main.roc")},\n' +
            '}\nimport Bench\n' + f'import {rel(data)} as input : List(U8)\n' + '\n'.join(imports) +
            '\nmain! = |level_number| Bench.run!(input, [' + ', '.join(cases) + f'], {args.reps}, level_number)\n')
        shutil.copyfile(PLATFORM / 'Bench.roc', stage / 'Bench.roc')
        shutil.copyfile(stage / 'Bench.roc', directory / 'Bench.roc')
        shutil.copyfile(stage / 'app.roc', directory / 'app.roc')
        run([args.roc, 'build', '--no-cache', '--opt=speed', stage / 'app.roc', '--output=' + str(directory / 'rocbench')])
        print('built', file, flush=True)
    metadata = dict(roc=str(args.roc), roc_sha256=digest(args.roc),
        roc_version=run([args.roc, 'version'], capture_output=True, text=True).stdout.strip(),
        staging_directory=str(PLATFORM / '.build/measurement'),
        package_sha256={str(p.relative_to(ROOT)):digest(p) for p in sorted((ROOT/'package').glob('*.roc'))},
        library=run(['git', '-C', ROOT, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip(),
        library_diff=run(['git', '-C', ROOT, 'diff', '--', 'package'], capture_output=True, text=True).stdout,
        libdeflate=run(['git', '-C', args.libdeflate, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip(),
        libdeflate_diff=run(['git', '-C', args.libdeflate, 'diff'], capture_output=True, text=True).stdout,
        files=args.files, levels=args.levels, reps=args.reps, driver_protocol='per-case-process-v1', warmup_min_ns=200000000,
        corpus_sha256={f:digest(args.corpus / f) for f in args.files},
        input_bytes={f:(args.corpus / f).stat().st_size for f in args.files},
        reference_sha256={f:{str(l):digest(out / f / f'level-{l}.deflate') for l in args.levels} for f in args.files},
        executable_sha256={f:{e:digest(args.out / f / e) for e in ['cbench','rocbench']} for f in args.files},
        platform_sha256={f:digest(PLATFORM / f) for f in ['host.c','main.roc','Host.roc','roc_platform_abi.h','Bench.roc','build.sh','measure.py']},
        target=target, system=run(['sw_vers'],capture_output=True,text=True).stdout,
        cpu=run(['sysctl','-n','machdep.cpu.brand_string'],capture_output=True,text=True).stdout.strip(),
        cc_version=run(['cc','--version'],capture_output=True,text=True).stdout)
    (out / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')

def measure(args):
    meta = json.loads((args.out / 'build.json').read_text())
    assert meta['driver_protocol'] == 'per-case-process-v1'
    assert args.rounds > 0
    for file in meta['files']:
        assert digest(args.corpus / file) == meta['corpus_sha256'][file]
        for level, expected_hash in meta['reference_sha256'][file].items():
            assert digest(args.out / file / f'level-{level}.deflate') == expected_hash
    execution = dict(rounds=args.rounds, started=time.strftime('%Y-%m-%dT%H:%M:%S%z'),
                     build_sha256=digest(args.out / 'build.json'))
    (args.out / 'run.json').write_text(json.dumps(execution, indent=2) + '\n')
    raw = args.out / 'raw'
    raw.mkdir(exist_ok=True)
    rows = []
    fields = ['engine','level','corpus','input_bytes','round','rep','ns','mb_per_s','compressed_bytes']
    with (args.out / 'timings.csv').open('w') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for round in range(1, args.rounds + 1):
            for file in meta['files']:
                directory = args.out / file
                for selected_level in meta['levels']:
                    for engine in (['libdeflate','roc-deflate'] if round % 2 else ['roc-deflate','libdeflate']):
                        binary = directory / ('cbench' if engine == 'libdeflate' else 'rocbench')
                        assert digest(binary) == meta['executable_sha256'][file][binary.name]
                        cmd = [binary, 'embedded', selected_level, meta['reps']] if engine == 'libdeflate' else [binary, selected_level]
                        output = run(cmd, capture_output=True, text=True, env={k:v for k,v in os.environ.items() if k not in ['DYLD_INSERT_LIBRARIES','LD_PRELOAD']}).stdout
                        (raw / f'{round}-{file}-{selected_level}-{engine}.txt').write_text(output)
                        samples = [line.split('\t') for line in output.splitlines() if line.startswith('rep\t')]
                        assert len(samples) == meta['reps'], output
                        assert {(int(s[1]),int(s[2])) for s in samples} == {(selected_level,r) for r in range(meta['reps'])}
                        for _, level, rep, ns, size in samples:
                            n = (args.corpus / file).stat().st_size
                            assert int(ns) > 0 and int(level) == selected_level
                            assert int(size) == (directory / f'level-{level}.deflate').stat().st_size
                            row = dict(engine=engine, level=int(level), corpus=file, input_bytes=n,
                                round=round, rep=int(rep)+1, ns=int(ns), mb_per_s=f'{n/int(ns)*1000:.2f}', compressed_bytes=int(size))
                            writer.writerow(row); rows.append(row)
                        handle.flush()
                print(f'round {round} {file} done {time.strftime("%H:%M:%S")}', flush=True)
    execution['finished'] = time.strftime('%Y-%m-%dT%H:%M:%S%z')
    execution['samples'] = len(rows)
    (args.out / 'run.json').write_text(json.dumps(execution, indent=2) + '\n')
    summarize(args.out)

def summarize(out):
    rows = list(csv.DictReader((out / 'timings.csv').open()))
    groups = {}
    for r in rows: groups.setdefault((r['corpus'], int(r['level']), r['engine']), []).append(int(r['ns']))
    result = []
    for file,level in sorted({k[:2] for k in groups}):
        c,roc = [statistics.median(groups[(file,level,e)]) for e in ['libdeflate','roc-deflate']]
        result.append(dict(corpus=file, level=level, c_ns=c, roc_ns=roc, gap_pct=(roc/c-1)*100))
    result.sort(key=lambda r:r['gap_pct'], reverse=True)
    with (out / 'summary.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=result[0].keys());w.writeheader();w.writerows(result)
    print(json.dumps(dict(worst=result[0],median=statistics.median(r['gap_pct'] for r in result), best=result[-1]),indent=2),flush=True)

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['build','run','all','summary'])
    p.add_argument('--roc',type=pathlib.Path,required=True)
    p.add_argument('--corpus',type=pathlib.Path,required=True)
    p.add_argument('--libdeflate',type=pathlib.Path,required=True)
    p.add_argument('--out',type=pathlib.Path,required=True)
    p.add_argument('--files',nargs='+',default=FILES)
    p.add_argument('--levels',nargs='+',type=int,default=list(range(1,13)))
    p.add_argument('--reps',type=int,default=5)
    p.add_argument('--rounds',type=int,default=3)
    args=p.parse_args()
    assert args.reps > 0 and args.rounds > 0
    assert args.levels and len(set(args.levels)) == len(args.levels) and all(1 <= l <= 12 for l in args.levels)
    assert args.files and len(set(args.files)) == len(args.files) and set(args.files) <= set(FILES)
    for key in ['roc','corpus','libdeflate','out']: setattr(args,key,getattr(args,key).resolve())
    if args.action in ['build','all']: build(args)
    if args.action in ['run','all']: measure(args)
    if args.action == 'summary': summarize(args.out)
