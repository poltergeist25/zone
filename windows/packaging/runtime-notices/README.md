# Microsoft build/runtime notices

The `.txt` files retain upstream Microsoft license text. These files do not mean that a new builder has accepted those terms, qualifies for Visual Studio Community, or has rights to redistribute every DLL found in a wheel. Each builder must establish their own applicable license and use authorized runtime inputs. No proprietary runtime DLLs are distributed in this source checkout.

`provenance.json` and `observed-runtime-files.json` are historical document/file inventories, not a new builder's acceptance record. `acquire-community-runtime.ps1` requires explicit `-AcceptLicense` for the person running it and verifies the official Microsoft bootstrapper signature. Use it only after reviewing eligibility and the current terms.

Primary sources:

- https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files
- https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution
- https://visualstudio.microsoft.com/license-terms/vs2022-ga-community/
- https://visualstudio.microsoft.com/license-terms/vs2022-cruntime/

Preserve required upstream notices and inventory the actual final build. Third-party open-source licenses do not relicense Microsoft runtime binaries.
