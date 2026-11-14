"""cycle_model.py -- 三方案周期数的控制级核算模型

用途：不跑仿真，按 RTL 状态机逐拍推演，验证 metrics.csv 里的 cycles
      并对拍数做分段归因（QK / softmax / PV、每行节奏）。
      三个方案的结果必须与实测逐拍相同，否则说明模型漏了某个握手。

用法：python hw/flow/collect/cycle_model.py
      # 期望输出 ref 9665 / varA 2855 / varB 1738，diff 全为 +0

注意：只模拟控制寄存器，不含数据通路；用于解释拍数，不能替代回归。
"""

"""逐拍模拟 ref / varA / varB 的控制状态机，核对 metrics.csv 的 cycles。
只模拟控制寄存器（不含数据通路），目的是给出可核对的拍数账本。
"""

N = 16
TIMEOUT = 60000


def sim_ref():
    """串行 baseline：QK 256*16 -> softmax 16*(MX16+EX16+DV44+NM16) -> PV 256*16"""
    st = 'IDLE'
    smph = 'MX'
    ci = cj = ck = 0
    div_start = False
    done = False
    # recip_unit
    r_ph, r_cnt, r_busy, r_done = 0, 0, False, False

    n = 0
    seg = {'QK': 0, 'MX': 0, 'EX': 0, 'DV': 0, 'NM': 0, 'PV': 0}
    while n < TIMEOUT:
        n += 1
        # ---- recip 本拍看到的输入 ----
        r_start = div_start
        r_done_seen = r_done

        # ---- top next ----
        n_st, n_smph = st, smph
        n_ci, n_cj, n_ck = ci, cj, ck
        n_div_start = False
        n_done = False

        if st == 'IDLE':
            if True:  # start 在第 1 拍已采样
                n_st = 'QK'
        elif st == 'QK':
            seg['QK'] += 1
            if ck == 15:
                n_ck = 0
                if cj == 15:
                    n_cj = 0
                    if ci == 15:
                        n_ci = 0
                        n_smph = 'MX'
                        n_st = 'SOFTMX'
                    else:
                        n_ci = ci + 1
                else:
                    n_cj = cj + 1
            else:
                n_ck = ck + 1
        elif st == 'SOFTMX':
            if smph == 'MX':
                seg['MX'] += 1
                if cj == 15:
                    n_cj = 0
                    n_smph = 'EX'
                else:
                    n_cj = cj + 1
            elif smph == 'EX':
                seg['EX'] += 1
                if cj == 15:
                    n_cj = 0
                    n_div_start = True
                    n_smph = 'DV'
                else:
                    n_cj = cj + 1
            elif smph == 'DV':
                seg['DV'] += 1
                if r_done_seen:
                    n_cj = 0
                    n_smph = 'NM'
            else:  # NM
                seg['NM'] += 1
                if cj == 15:
                    n_cj = 0
                    if ci == 15:
                        n_ci = 0
                        n_ck = 0
                        n_st = 'PV'
                    else:
                        n_ci = ci + 1
                        n_smph = 'MX'
                else:
                    n_cj = cj + 1
        elif st == 'PV':
            seg['PV'] += 1
            if ck == 15:
                n_ck = 0
                if cj == 15:
                    n_cj = 0
                    if ci == 15:
                        n_ci = 0
                        n_done = True
                        n_st = 'DONE'
                    else:
                        n_ci = ci + 1
                else:
                    n_cj = cj + 1
            else:
                n_ck = ck + 1
        elif st == 'DONE':
            n_st = 'IDLE'

        # ---- recip next ----
        n_r_ph, n_r_cnt, n_r_busy, n_r_done = r_ph, r_cnt, r_busy, r_done
        n_r_done = False
        if r_ph == 0:
            if not r_busy:
                if r_start:
                    n_r_busy = True
                    n_r_cnt = 0
            else:
                if r_cnt == 40:
                    n_r_ph = 1
                else:
                    n_r_cnt = r_cnt + 1
        elif r_ph == 1:
            n_r_busy = False
            n_r_done = True
            n_r_ph = 2
        else:
            n_r_ph = 0

        # commit
        st, smph = n_st, n_smph
        ci, cj, ck = n_ci, n_cj, n_ck
        div_start = n_div_start
        done = n_done
        r_ph, r_cnt, r_busy, r_done = n_r_ph, n_r_cnt, n_r_busy, n_r_done

        if done:
            return n, seg, True
    return n, seg, False


def sim_vara():
    """varA：QK 4 拍/元素，softmax 三级流水，PV 4 拍/元素（满算）"""
    st = 'IDLE'
    ci = cj = cg = 0
    pv_first = True
    pv_done = 0
    bank_busy = [False, False]
    a_busy = False
    a_ph = 0
    a_row = 0
    a_j = 0
    a_bank = 0
    a2b_v = False
    a2b_b = 0
    b_busy = False
    b_bank = 0
    b2c_v = False
    b2c_b = 0
    c_busy = False
    c_bank = 0
    c_j = 0
    nfin = 0
    div_start = False
    done = False
    r_ph, r_cnt, r_busy, r_done = 0, 0, False, False

    n = 0
    seg = {'QK': 0, 'A': 0, 'B': 0, 'C': 0, 'PV': 0, 'SM_wall': 0}
    trace = {'a_start': [], 'c_done': []}
    while n < TIMEOUT:
        n += 1
        r_done_seen = r_done
        n_st = st
        n_ci, n_cj, n_cg = ci, cj, cg
        n_pv_first, n_pv_done = pv_first, pv_done
        n_bank = list(bank_busy)
        n_a_busy, n_a_ph, n_a_row, n_a_j, n_a_bank = a_busy, a_ph, a_row, a_j, a_bank
        n_a2b_v = a2b_v
        n_a2b_b = a2b_b
        n_b_busy = b_busy
        n_b_bank = b_bank
        n_b2c_v = False
        n_b2c_b = b2c_b
        n_c_busy = c_busy
        n_c_bank = c_bank
        n_c_j = c_j
        n_nfin = nfin
        n_div_start = False
        n_done = False

        if st == 'SOFTMX':
            seg['SM_wall'] += 1
            # A 级
            if not a_busy:
                if a_row < N and not (bank_busy[0] and bank_busy[1]):
                    n_a_busy = True
                    n_a_ph = 0
                    n_a_j = 0
                    n_a_bank = 1 if bank_busy[0] else 0
                    n_bank[n_a_bank] = True
                    trace['a_start'].append((n, a_row))
            elif a_ph == 0:
                seg['A'] += 1
                if a_j == N - 1:
                    n_a_j = 0
                    n_a_ph = 1
                else:
                    n_a_j = a_j + 1
            else:
                seg['A'] += 1
                if a_j == N - 1:
                    n_a_busy = False
                    n_a_row = a_row + 1
                    n_a2b_v = True
                    n_a2b_b = a_bank
                else:
                    n_a_j = a_j + 1

            # B 级
            if not b_busy:
                if a2b_v:
                    n_b_busy = True
                    n_a2b_v = False
                    n_b_bank = a2b_b
                    n_div_start = True
            elif r_done_seen:
                n_b_busy = False
                n_b2c_v = True
                n_b2c_b = b_bank

            # C 级
            if not c_busy:
                if b2c_v:
                    n_c_busy = True
                    n_c_bank = b2c_b
                    n_c_j = 0
                    n_b2c_v = False
            else:
                seg['C'] += 1
                if c_j == N - 1:
                    n_c_busy = False
                    n_nfin = nfin + 1
                    n_bank[c_bank] = False
                    trace['c_done'].append((n, a_row))
                else:
                    n_c_j = c_j + 1

        if st == 'IDLE':
            n_st = 'QK'
        elif st == 'QK':
            seg['QK'] += 1
            if cg == 3:
                n_cg = 0
                if cj == 15:
                    n_cj = 0
                    if ci == 15:
                        n_ci = 0
                        n_st = 'SOFTMX'
                    else:
                        n_ci = ci + 1
                else:
                    n_cj = cj + 1
            else:
                n_cg = cg + 1
        elif st == 'SOFTMX':
            if nfin == N:  # 注意：这里用本拍已提交的 nfin
                n_ci = 0
                n_cj = 0
                n_pv_first = True
                n_pv_done = 0
                n_st = 'PV'
        elif st == 'PV':
            seg['PV'] += 1
            if pv_first:
                pg, pg2 = 0, 1
            else:
                pg = pv_done + 1
                pg2 = pg + 1
            pv_have = True
            pv_last = (pg2 > 3)
            if pv_have and not pv_last:
                n_pv_done = pg
                n_pv_first = False
            else:
                n_pv_first = True
                n_pv_done = 0
                if cj == 15:
                    n_cj = 0
                    if ci == 15:
                        n_ci = 0
                        n_done = True
                        n_st = 'DONE'
                    else:
                        n_ci = ci + 1
                else:
                    n_cj = cj + 1
        elif st == 'DONE':
            n_st = 'IDLE'

        n_r_ph, n_r_cnt, n_r_busy, n_r_done = r_ph, r_cnt, r_busy, False
        if r_ph == 0:
            if not r_busy:
                if div_start:
                    n_r_busy = True
                    n_r_cnt = 0
            else:
                if r_cnt == 40:
                    n_r_ph = 1
                else:
                    n_r_cnt = r_cnt + 1
        elif r_ph == 1:
            n_r_busy = False
            n_r_done = True
            n_r_ph = 2
        else:
            n_r_ph = 0

        st = n_st
        ci, cj, cg = n_ci, n_cj, n_cg
        pv_first, pv_done = n_pv_first, n_pv_done
        bank_busy = n_bank
        a_busy, a_ph, a_row, a_j, a_bank = n_a_busy, n_a_ph, n_a_row, n_a_j, n_a_bank
        a2b_v = n_a2b_v
        a2b_b = n_a2b_b
        b_busy = n_b_busy
        b_bank = n_b_bank
        b2c_v = n_b2c_v
        b2c_b = n_b2c_b
        c_busy = n_c_busy
        c_bank = n_c_bank
        c_j = n_c_j
        nfin = n_nfin
        div_start = n_div_start
        done = n_done
        r_ph, r_cnt, r_busy, r_done = n_r_ph, n_r_cnt, n_r_busy, n_r_done

        if done:
            return n, seg, True, trace
    return n, seg, False, trace


def sim_varb():
    """varB：整条行流水（A: QK+exp / B: 倒数 / C: 归一+P·V）"""
    st = 'IDLE'
    nfin = 0
    bank_busy = [False, False]
    a_busy = False
    a_ph = 0
    a_row = 0
    a_j = 0
    a_g = 0
    a_bank = 0
    a2b_v = False
    b_busy = False
    b2c_v = False
    c_busy = False
    c_ph = 0
    c_row = 0
    c_j = 0
    pv_first = True
    pv_done = 0
    div_start = False
    done = False
    r_ph, r_cnt, r_busy, r_done = 0, 0, False, False

    n = 0
    seg = {'A': 0, 'B': 0, 'C': 0, 'wall': 0}
    trace = {'a_start': [], 'c_done': [], 'c_start': []}
    while n < TIMEOUT:
        n += 1
        r_done_seen = r_done
        n_st = st
        n_nfin = nfin
        n_bank = list(bank_busy)
        n_a_busy, n_a_ph, n_a_row, n_a_j, n_a_g, n_a_bank = a_busy, a_ph, a_row, a_j, a_g, a_bank
        n_a2b_v = a2b_v
        n_b_busy = b_busy
        n_b2c_v = False
        n_c_busy = c_busy
        n_c_ph = c_ph
        n_c_row = c_row
        n_c_j = c_j
        n_pv_first, n_pv_done = pv_first, pv_done
        n_div_start = False
        n_done = False

        if st == 'QK':
            seg['wall'] += 1
            # A
            if not a_busy:
                if a_row < N and not (bank_busy[0] and bank_busy[1]):
                    n_a_busy = True
                    n_a_ph = 0
                    n_a_j = 0
                    n_a_g = 0
                    n_a_bank = 1 if bank_busy[0] else 0
                    n_bank[n_a_bank] = True
                    trace['a_start'].append((n, a_row))
            elif a_ph == 0:
                seg['A'] += 1
                if a_g == 3:
                    n_a_g = 0
                    if a_j == N - 1:
                        n_a_j = 0
                        n_a_ph = 1
                    else:
                        n_a_j = a_j + 1
                else:
                    n_a_g = a_g + 1
            else:
                seg['A'] += 1
                if a_j == N - 1:
                    n_a_busy = False
                    n_a_row = a_row + 1
                    n_a2b_v = True
                else:
                    n_a_j = a_j + 1
            # B
            if not b_busy:
                if a2b_v:
                    n_b_busy = True
                    n_a2b_v = False
                    n_div_start = True
            elif r_done_seen:
                n_b_busy = False
                n_b2c_v = True
            # C
            if not c_busy:
                if b2c_v:
                    n_c_busy = True
                    n_c_ph = 0
                    n_c_j = 0
                    n_b2c_v = False
                    trace['c_start'].append((n, c_row))
            elif c_ph == 0:
                seg['C'] += 1
                if c_j == N - 1:
                    n_c_ph = 1
                    n_c_j = 0
                    n_pv_first = True
                    n_pv_done = 0
                else:
                    n_c_j = c_j + 1
            else:
                seg['C'] += 1
                if pv_first:
                    pg, pg2 = 0, 1
                else:
                    pg = pv_done + 1
                    pg2 = pg + 1
                pv_last = (pg2 > 3)
                if not pv_last:
                    n_pv_done = pg
                    n_pv_first = False
                else:
                    n_pv_first = True
                    n_pv_done = 0
                    if c_j == N - 1:
                        n_c_busy = False
                        n_c_row = c_row + 1
                        n_nfin = nfin + 1
                        if c_row == N - 1:
                            n_done = True
                        trace['c_done'].append((n, c_row))
                        if n_bank[0]:
                            n_bank[0] = False
                        else:
                            n_bank[1] = False
                    else:
                        n_c_j = c_j + 1

        if st == 'IDLE':
            n_st = 'QK'
        elif st == 'QK':
            if nfin == N:
                n_st = 'DONE'
        elif st == 'DONE':
            n_st = 'IDLE'

        n_r_ph, n_r_cnt, n_r_busy, n_r_done = r_ph, r_cnt, r_busy, False
        if r_ph == 0:
            if not r_busy:
                if div_start:
                    n_r_busy = True
                    n_r_cnt = 0
            else:
                if r_cnt == 40:
                    n_r_ph = 1
                else:
                    n_r_cnt = r_cnt + 1
        elif r_ph == 1:
            n_r_busy = False
            n_r_done = True
            n_r_ph = 2
        else:
            n_r_ph = 0

        st = n_st
        nfin = n_nfin
        bank_busy = n_bank
        a_busy, a_ph, a_row, a_j, a_g, a_bank = n_a_busy, n_a_ph, n_a_row, n_a_j, n_a_g, n_a_bank
        a2b_v = n_a2b_v
        b_busy = n_b_busy
        b2c_v = n_b2c_v
        c_busy = n_c_busy
        c_ph = n_c_ph
        c_row = n_c_row
        c_j = n_c_j
        pv_first, pv_done = n_pv_first, n_pv_done
        div_start = n_div_start
        done = n_done
        r_ph, r_cnt, r_busy, r_done = n_r_ph, n_r_cnt, n_r_busy, n_r_done

        if done:
            return n, seg, True, trace
    return n, seg, False, trace


res = {}
for name, fn, ref in [('ref', sim_ref, 9665), ('varA', sim_vara, 2855), ('varB', sim_varb, 1738)]:
    out = fn()
    cycles, seg, ok = out[0], out[1], out[2]
    tr = out[3] if len(out) > 3 else None
    res[name] = (cycles, seg, tr)
    print(f'{name:5s} sim={cycles:6d}  csv={ref:6d}  diff={cycles-ref:+4d}   done={ok}')
    print('        ', {k: v for k, v in seg.items() if v})
    if tr:
        ast = [t for t, _ in tr['a_start']][:6]
        cst = [t for t, _ in tr.get('c_start', [])][:6]
        cdn = [t for t, _ in tr['c_done']]
        print('         A start:', ast, '... C start:', cst)
        print('         C done :', cdn[:6], '... last', cdn[-3:] if cdn else None)
        if len(cdn) > 2:
            gaps = [cdn[i+1]-cdn[i] for i in range(len(cdn)-1)]
            print('         行间隔 :', gaps)
