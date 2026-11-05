// guard_test.c — 循环守卫判定的算法级自测（在本机 clang 下可直接跑）
//
// 目的：Swift 侧无法在本设备编译（无 swiftc），但守卫的**判定逻辑**可以先在 C 里
// 用同一套算法验证，确认阈值与 streak 语义正确，再把结论映射回 Swift 实现。
// 编译：clang -O2 guard_test.c -o guard_test && ./guard_test
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define MAXH 40
typedef struct { char tool[64]; char args[64]; char res[64]; int unknown; int poll; } Rec;

static Rec hist[MAXH];
static int hist_n = 0;

static void push(const char*t,const char*a,const char*r,int unk,int poll){
    if (hist_n==MAXH){ memmove(hist,hist+1,sizeof(Rec)*(MAXH-1)); hist_n--; }
    Rec*x=&hist[hist_n++]; memset(x,0,sizeof(*x));
    snprintf(x->tool,64,"%s",t); snprintf(x->args,64,"%s",a);
    snprintf(x->res,64,"%s",r); x->unknown=unk; x->poll=poll;
}

// 返回 no-progress 连击、同参连击
static void streaks(const char*t,const char*a,int*noProg,int*sameArgs){
    *noProg=0; *sameArgs=0; char first[64]; int haveFirst=0;
    for(int i=hist_n-1;i>=0;i--){
        if(strcmp(hist[i].tool,t)||strcmp(hist[i].args,a)) break;
        (*sameArgs)++;
        if(!hist[i].res[0]) break;   /* 未知结果同样中断连击 */
        if(haveFirst){ if(strcmp(hist[i].res,first)) break; }
        else { snprintf(first,64,"%s",hist[i].res); haveFirst=1; }
        (*noProg)++;
    }
}

static int fails=0;
static void expect(const char*name,int got,int want){
    if(got!=want){ printf("FAIL %s: got %d want %d\n",name,got,want); fails++; }
    else printf("ok   %s = %d\n",name,got);
}

int main(void){
    // 场景1：同参同结果 4 次 → no-progress 连击应为 3（本次之前已有 3 条）
    for(int i=0;i<3;i++) push("shell.exec","h1","r1",0,0);
    int np,sa; streaks("shell.exec","h1",&np,&sa);
    expect("no_progress 连击",np,3);
    expect("same_args 连击",sa,3);
    // 阈值 4 → 加上即将执行的第 4 次应为 block
    expect("第4次应阻断",(np+1)>=4,1);

    // 场景2：结果变化 → no-progress 归零，同参仍累计
    hist_n=0;
    push("t","h","r1",0,0); push("t","h","r2",0,0);
    streaks("t","h",&np,&sa);
    expect("结果变化 no_progress",np,1);
    expect("结果变化 same_args",sa,2);

    // 场景3：轮询工具放宽阈值（12）
    hist_n=0;
    for(int i=0;i<11;i++) push("device.status","h","same",0,1);
    streaks("device.status","h",&np,&sa);
    expect("轮询 11 次不阻断",np<12,1);

    // 场景4：unknown tool 连击
    hist_n=0;
    push("bogus","h","err:unknown",1,0);
    push("bogus","h","err:unknown",1,0);
    push("bogus","h","err:unknown",1,0);
    int un=0; for(int i=hist_n-1;i>=0;i--){ if(!hist[i].unknown) break; un++; }
    expect("unknown 连击",un,3);
    expect("unknown 达阈值阻断",un>=3,1);

    // 场景5：中间换过工具 → 连击断掉（不该跨工具累计）
    hist_n=0;
    push("t","h","r1",0,0); push("other","h2","r9",0,0); push("t","h","r1",0,0);
    streaks("t","h",&np,&sa);
    expect("跨工具不连续 no_progress",np,1);
    expect("跨工具不连续 same_args",sa,1);

    // 场景6：超时未定局（res 为空）要中断 no-progress 连击，但同参仍计数
    hist_n=0;
    push("t","h","r1",0,0); push("t","h","",0,0); push("t","h","r1",0,0);
    streaks("t","h",&np,&sa);
    expect("超时中断 no_progress",np,1);
    expect("超时仍计 same_args",sa,2);  /* break 在未知结果处停下：只数到中断点 */

    printf(fails? "\n%d 项失败\n":"\n全部通过\n",fails);
    return fails?1:0;
}
