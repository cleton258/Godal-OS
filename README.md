# GODAL OS – Emulador Optimizer

App para Windows (Electron) com a interface GODAL OS e o robô como ícone.
A interface chama o script `scripts/GODAL_OS.ps1` (modo `-Json`) e mostra cada etapa em tempo real.

## Compilar no GitHub (sem instalar nada)
1. Crie um repositório e envie **todo o conteúdo desta pasta** (incluindo a pasta `.github`).
2. Abra a aba **Actions** → **Build GODAL OS (Windows)** → **Run workflow**
   (também roda sozinho a cada push na branch `main`).
3. Ao terminar, baixe **GODAL-OS-windows** em *Artifacts*:
   - `GODAL-OS-Setup-1.0.0.exe` → instalador (cria o atalho na área de trabalho com o ícone do robô)
   - `GODAL-OS-Portable-1.0.0.exe` → versão portátil, sem instalar
4. Para publicar um Release: `git tag v1.0.0 && git push origin v1.0.0`.

## Compilar no seu PC
```
npm install
npm run build      # gera dist/*.exe
```
Testar sem compilar: `npm start` (abra o terminal **como administrador**).

## Estrutura
```
main.js / preload.js    processo principal (janela, hardware, executa o .ps1)
src/index.html, app.js  interface
src/img/robo.png        robô (imagem da interface)
build/icon.ico|png      ícone do .exe / atalho
scripts/GODAL_OS.ps1    otimização e restauração (saída ##SEC/##RUN/##STEP/##IA para a interface)
.github/workflows       compilação automática
```

O .exe pede administrador ao abrir (necessário para os ajustes). Sem assinatura digital, o Windows SmartScreen pode avisar na primeira vez: **Mais informações → Executar assim mesmo**.
