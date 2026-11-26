---
name: ios-testflight
description: Build DSH Go for iOS from the fork and ship it to TestFlight, including the bundle-id swap, the signing team, the 90035 script rule, the altool upload and export compliance. Use for every iOS build or TestFlight upload here, and for /ios-testflight.
---

# TestFlight do DSH Go, a partir do fork

Objetivo: transformar o código do fork em um build que a Apple aceita e que os testadores internos
recebem. O caminho abaixo foi executado de ponta a ponta em 2026-11-26 (builds 1.3.0(7) e 1.3.0(8)).

## Antes de tudo: qual código

- Base é sempre o `main` do fork `risaddex/dsh-Go`. O upstream `ccch1mneyyy/dsh-go` **não tem o
  painel do deck** (`app/lib/ui/plugins/deck/`, feature `deck.panel.read.v1` no host): build feito do
  upstream sobe sem a aba de plugins.
- Do upstream vem só **cherry-pick**, conforme sair (skill `ios-upstream-cherry-pick`, que vive no
  branch `ios-testflight-1.2.0`).

## Passos

1. Clone do fork. **Não** rode `tooling/ios/prepare-engine.sh`: sem `app/ios/Engine/.ready` o
   `embed-engine.sh` imprime *"connects to remote hosts only"* e segue — é o desejado para o TestFlight
   (o app fica só cliente remoto, sem NodeMobile/iSH).
2. Troque o bundle id em `app/ios`: `io.github.ccch1mneyyy.dshgo` → `com.danilo.dshgo`.
   São ~14 arquivos: `project.pbxproj`, os três `.entitlements` (App Groups viram
   `group.com.danilo.dshgo`, keychain-access-groups ficam com o prefixo do time), os dois `Info.plist`
   (`DSHCompanionAccessGroup`), `ShareExtension/ShareInbox.swift` e os Swift do `Runner`.
3. Assinatura: em **cada** configuração que tenha `PRODUCT_BUNDLE_IDENTIFIER`, grave
   `DEVELOPMENT_TEAM = 7F3YZDJ6L8` e `CODE_SIGN_STYLE = Automatic` (Runner, ShareExtension,
   CompanionWidget e as extensões). Certificado da máquina: "Apple Distribution: Ramtec Servicos De
   Informatica Ltda".
4. **Remova os scripts dos assets antes de compilar**:
   `find app/assets -type f \( -name '*.py' -o -name '*.mjs' -o -name '*.sh' \) -delete` (11 arquivos).
   Sem isso a Apple recusa o upload com **90035** *"code object is not signed at all"* — script dentro do
   bundle conta como código. Num cliente remoto eles não servem para nada.
5. `cd app && flutter pub get && flutter build ipa --release --build-number N`, com **N maior que o
   último build daquela versão**. A versão de marketing vem do `pubspec.yaml`.
6. Upload:
   `xcrun altool --upload-app -f build/ios/ipa/dsh_app.ipa -t ios --apiKey C93V33X8QS --apiIssuer 69a6de97-a750-47e3-e053-5b8c7c11a4d1`
   App na App Store Connect: **6837234038** (`com.danilo.dshgo`). Chave: `~/.appstoreconnect/private_keys/AuthKey_C93V33X8QS.p8`.
7. Conformidade: o build novo nasce com `usesNonExemptEncryption = null` e **fica bloqueado para teste**
   até responder. Responda `false` (só TLS) por PATCH em `/v1/builds/<id>`.
8. Confirme: `processingState = VALID`. Para provar que o painel do deck entrou, rode
   `strings .../Runner.app/Frameworks/App.framework/App | grep -c deck.panel.read` — tem de dar ≥ 1
   (build do upstream dá 0).

## Armadilhas já pagas

| Sintoma | Causa | Saída |
| --- | --- | --- |
| 90035 *code object is not signed at all* | script no bundle | passo 4 |
| build enviado não aparece no TestFlight | conformidade `null` | passo 7 |
| `"Cannot add internal group to a build"` (422) | grupo interno recebe build sozinho | não atribua; só confira |
| upload recusado por número de build | N ≤ último da mesma versão | suba o N |
| app sobe sem a aba de plugins | build saiu do upstream | refaça a partir do fork |
| IPA monta mas não instala no iPhone | IPA é de **distribuição** | para instalar direto use `flutter run --release -d <udid>` (assinatura de development) |
