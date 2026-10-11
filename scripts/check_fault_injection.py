import json
import shutil
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from model.reference import MAP, MASK, compare, read_hex
from model.pipeline_check import compare_pipeline

def is_m(insn, f3s, word):
    return (insn & 127) == (0x3b if word else 0x33) and insn >> 25 == 1 and (insn >> 12) & 7 in f3s

M_FAULTS = {
    'mulh_high_product': ('m_mul_edges', {1}, False, lambda v: v not in (0, MASK), lambda v: v ^ 1),
    'mulhsu_signedness': ('m_mul_edges', {2}, False, lambda v: v != 0, lambda v: v ^ (1 << 63)),
    'mulw_sign_extension': ('m_mul_edges', {0}, True, lambda v: v >> 32 == 0xffffffff, lambda v: v & 0xffffffff),
    'signed_division_rounding': ('m_div_edges', {4}, False, lambda v: v >> 63 and v != MASK and v != 1 << 63, lambda v: v - 1),
    'remainder_sign': ('m_div_edges', {6}, False, lambda v: v >> 63 and v != 1 << 63, lambda v: (-v) & MASK),
    'divuw_sign_extension': ('m_divw_edges', {5, 7}, True, lambda v: v >> 32 == 0xffffffff, lambda v: v & 0xffffffff),
    'duplicate_m_completion': ('m_mixed', set(range(8)), False, lambda v: True, None),
    'missing_m_retirement': ('m_mixed', set(range(8)), False, lambda v: True, None),
}

def inject_m(fault, lines):
    case, f3s, word, predicate, mutate = M_FAULTS[fault]
    for index, line in enumerate(lines):
        fields = line.split(',')
        if not (len(fields) == 13 and fields[0].isdigit()): continue
        insn, rd, value = int(fields[2], 16), int(fields[4]), int(fields[5], 16)
        if rd == 0 or not is_m(insn, f3s, word) or not predicate(value): continue
        if fault == 'duplicate_m_completion': lines.insert(index + 1, line)
        elif fault == 'missing_m_retirement': lines.pop(index)
        else:
            fields[5] = f'{mutate(value):x}'
            lines[index] = ','.join(fields)
        return
    raise AssertionError(f'No injection target: {fault}')

def retirement(fields): return len(fields) in (13, 14) and fields[0].isdigit()

def inject_pipeline(fault, lines):
    index = lambda tag, pred=lambda f: True: next(i for i, l in enumerate(lines) if l.split(',')[0] == tag and pred(l.split(',')))
    if fault == 'pipe_wrong_path_store':
        q = index('Q', lambda f: f[2] == '1')
        f = lines[q].split(','); f[1] = f'{int(f[1], 16) + 24:016x}'
        lines[q:q] = [','.join(f), 'R,0,0000000000000000']
    elif fault == 'pipe_duplicate_store':
        q = index('Q', lambda f: f[2] == '1')
        lines[q:q] = [lines[q], 'R,0,0000000000000000']
    elif fault == 'pipe_reordered_data':
        q = [i for i, l in enumerate(lines) if l.startswith('Q,')][:2]
        r = [i for i, l in enumerate(lines) if l.startswith('R,')][:2]
        lines[q[0]], lines[q[1]] = lines[q[1]], lines[q[0]]
        lines[r[0]], lines[r[1]] = lines[r[1]], lines[r[0]]
    elif fault == 'pipe_store_retired_before_ack':
        q = index('Q', lambda f: f[2] == '1'); r = next(i for i in range(q + 1, len(lines)) if lines[i].startswith('R,'))
        ret = next(i for i in range(r + 1, len(lines)) if retirement(lines[i].split(',')) and int(lines[i].split(',')[8], 16))
        lines.insert(ret + 1, lines.pop(r))
    elif fault == 'pipe_fetch_data':
        r = index('IR'); f = lines[r].split(','); f[2] = f'{int(f[2], 16) ^ (1 << 20):016x}'; lines[r] = ','.join(f)
    elif fault == 'pipe_fetch_mask':
        q = index('IQ'); f = lines[q].split(','); f[3] = '0f'; lines[q] = ','.join(f)
    elif fault == 'pipe_forwarded_result':
        r = [i for i, l in enumerate(lines) if retirement(l.split(','))][2]
        f = lines[r].split(','); f[5] = f'{int(f[5], 16) ^ 5:x}'; lines[r] = ','.join(f)
    elif fault == 'pipe_missing_load_response':
        q = index('Q', lambda f: f[2] == '0')
        lines.pop(next(i for i in range(q + 1, len(lines)) if lines[i].startswith('R,')))
    else: raise AssertionError(fault)

PIPELINE_FAULTS = ('pipe_wrong_path_store', 'pipe_duplicate_store', 'pipe_reordered_data', 'pipe_store_retired_before_ack',
                   'pipe_fetch_data', 'pipe_fetch_mask', 'pipe_forwarded_result', 'pipe_missing_load_response')

def pipeline_main(out):
    results = []
    case = 'pipe_forward'
    source = ROOT / f'build/xsim_pipe/{case}_s1_d5_r-1.csv'
    for fault in PIPELINE_FAULTS:
        lines = source.read_text().splitlines()
        inject_pipeline(fault, lines)
        target = out / f'{fault}.csv'
        target.write_text('\n'.join(lines) + '\n')
        shutil.copyfile(str(source) + '.mem', str(target) + '.mem')
        try:
            compare_pipeline(read_hex(ROOT / f'build/programs/{case}.hex'), target)
        except (AssertionError, StopIteration) as error:
            results.append({'injected_fault': fault, 'result': 'DETECTED', 'diagnostic': str(error)})
        else: raise AssertionError(f'Pipeline checker missed deliberate injection: {fault}')
    compare_pipeline(read_hex(ROOT / f'build/programs/{case}.hex'), source)
    return results

def main():
    out = ROOT / 'build/injected_traces'
    out.mkdir(exist_ok=True)
    results = []
    for fault,case in [('word_sign_extension','word_ops'),('branch_next_pc','control'),
                       ('store_data','memory_sizes'),('store_mask','memory_sizes'),
                       ('duplicate_store','memory_sizes'),('missing_store','memory_sizes'),
                       ('response_data','memory_sizes'),('final_memory','memory_sizes')] + [
                       (fault, spec[0]) for fault, spec in M_FAULTS.items()]:
        source = ROOT / f'build/xsim_core/{case}_s1_d5_r-1.csv'
        target = out / f'{fault}.csv'
        lines = source.read_text().splitlines()
        request_address = 0
        if fault in M_FAULTS: inject_m(fault, lines)
        for index,line in enumerate([] if fault in M_FAULTS else lines):
            fields = line.split(',')
            if fields[0] == 'Q': request_address = int(fields[1],16)
            retirement = len(fields) == 13 and fields[0].isdigit()
            if (fault == 'word_sign_extension' and retirement and
                int(fields[2],16) & 127 in (0x1b,0x3b) and int(fields[5],16) >> 32 == 0xffffffff):
                fields[5] = f'{int(fields[5],16) & 0xffffffff:x}'
            elif fault == 'branch_next_pc' and retirement and int(fields[2],16) & 127 == 0x63:
                fields[3] = f'{int(fields[3],16) ^ 4:x}'
            elif fault in ('store_data','store_mask','duplicate_store','missing_store') and fields[0] == 'Q' and fields[2] == '1':
                if fault == 'duplicate_store': lines.insert(index,line); break
                if fault == 'missing_store': lines.pop(index); break
                column = 4 if fault == 'store_data' else 3
                fields[column] = f'{int(fields[column],16)^1:x}'
            elif fault == 'response_data' and fields[0] == 'R' and request_address >= MAP['ram_base']+0x4000 and int(fields[2],16):
                fields[2] = f'{int(fields[2],16)^1:x}'
            else: continue
            lines[index] = ','.join(fields)
            break
        else:
            if fault != 'final_memory' and fault not in M_FAULTS: raise AssertionError(f'No injection target: {fault}')
        target.write_text('\n'.join(lines)+'\n')
        shutil.copyfile(str(source)+'.mem',str(target)+'.mem')
        if fault == 'final_memory':
            memory = Path(str(target)+'.mem')
            content = memory.read_text().splitlines(); content[-1] = f'{int(content[-1],16)^1:02x}'
            memory.write_text('\n'.join(content)+'\n')
        try:
            compare(read_hex(ROOT/f'build/programs/{case}.hex'),target,require_bus=True)
        except AssertionError as error:
            results.append({'injected_fault':fault,'result':'DETECTED','diagnostic':str(error)})
        else: raise AssertionError(f'Checker missed deliberate injection: {fault}')
    pipe_results = pipeline_main(out)
    (ROOT/'build/fault_injection.json').write_text(json.dumps(results + pipe_results,indent=2)+'\n')
    print(f'PASS: detected {len(results)} multicycle and {len(pipe_results)} pipeline deliberate corruptions of actual RTL outputs')

if __name__ == '__main__': main()
