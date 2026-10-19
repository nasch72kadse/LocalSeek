#include "localseek_llama.h"
#include <cstdio>
#include <cstring>
int main(int argc, char** argv) {
    ls_llama_ctx* h = ls_llama_load(argv[1]);
    printf("load handle: %p\n", (void*)h);
    if (!h) { printf("LOAD FAILED\n"); return 1; }
    int ne = ls_llama_n_embd(h);
    printf("n_embd: %d\n", ne);
    const char* samples[] = {
        "passage: Risiko und Zahlung im Vertrag",
        "passage: Grosse Zusammenfassung mit Umlauten aeoeue und Zahlen 1234",
        "query: wo steht etwas ueber Zahlungen"
    };
    for (int i=0;i<3;i++){
        float out[1024];
        int rc = ls_llama_embed(h, samples[i], out, ne>0?ne:384);
        printf("embed[%d] rc=%d first=%.5f\n", i, rc, out[0]);
    }
    ls_llama_free(h);
    return 0;
}
