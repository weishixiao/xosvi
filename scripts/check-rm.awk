# check-rm.awk —— 递归删除的变量守卫检查（单文件，由 scripts/check.sh 逐文件调用）
#
# 规则：`rm -r` / `rm -rf` 目标里出现的每个变量，必须满足其一：
#   1) 写作 ${VAR:?}（空值让 shell 立即退出，不落到真实的 /）
#   2) 本脚本里赋过值，且赋值的右侧本身不依赖外部输入（不含 $1/$@/$*/命令替换），
#      也就是这个变量是脚本自己派生的常量链，不是调用者能传空的环境输入
#   3) 本文件里有全局守卫 : "${VAR:?}"
# 否则输出 "行号: VAR VAR ..."，由 scripts/check.sh 报 FAIL。
#
# 这条规则来自 Apelin 的 check-shell-deletes.py：roothide 的 / 是 bootstrap 根，
# 一个空的递归删除变量足以删掉整套环境，而维护脚本还是 root 跑的。

{
    lines[FNR] = $0
}

END {
    # ---- 第一遍：收集赋值与全局守卫 -----------------------------------------
    for (i = 1; i <= FNR; i++) {
        line = lines[i]

        if (match(line, /\$\{[A-Za-z_][A-Za-z0-9_]*:\?/)) {
            t = substr(line, RSTART, RLENGTH)
            sub(/^\$\{/, "", t)
            sub(/:\?$/, "", t)
            guarded[t] = 1
        }

        if (match(line, /^[[:space:]]*(export[[:space:]]+|local[[:space:]]+|readonly[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
            decl = substr(line, RSTART, RLENGTH)
            name = decl
            gsub(/[[:space:]]+/, "", name)
            sub(/^export/, "", name); sub(/^local/, "", name); sub(/^readonly/, "", name)
            sub(/=$/, "", name)
            rhs = substr(line, RSTART + RLENGTH)
            # 调用者能传空/能替换成任意路径的右侧：$1 $@ $* $(...) 以及反引号。
            if (rhs ~ /\$1[^0-9]|$1$/ || rhs ~ /\$[@*]/ || rhs ~ /\$[(]|`/) {
                unsafe[name] = 1
            } else {
                derived[name] = 1
            }
            assignCount[name]++
        }
    }

    # ---- 第二遍：检查递归删除 ---------------------------------------------
    for (i = 1; i <= FNR; i++) {
        line = lines[i]
        if (line !~ /(^|[[:space:];&|(])rm[[:space:]]/) continue
        if (line !~ /^[[:space:]]*(sudo[[:space:]]+)?[A-Za-z ]*rm[[:space:]]+-[A-Za-z]*[rR]/ &&
            line !~ /rm[[:space:]]+-[A-Za-z]*[rR]/) continue
        code = line
        sub(/#.*/, "", code)
        if (code !~ /rm[[:space:]]/) continue
        # 只关心带 -r / -R / --recursive 的那一条命令
        if (code !~ /-[A-Za-z]*[rR][A-Za-z]*[[:space:]]/ && code !~ /--recursive/) continue

        bad = ""
        tmp = code
        while (match(tmp, /[$][{]?[A-Za-z_][A-Za-z0-9_]*/)) {
            tok = substr(tmp, RSTART, RLENGTH)
            name = tok
            sub(/^\$[{]?/, "", name)
            rest = substr(tmp, RSTART + RLENGTH)
            ok = (rest ~ /^:\?/) || (name in guarded) || ((name in derived) && !(name in unsafe))
            if (!ok && index(" " bad " ", " " name " ") == 0) bad = bad " " name
            tmp = rest
        }
        if (bad != "") printf "%d:%s\n", i, bad
    }
}
