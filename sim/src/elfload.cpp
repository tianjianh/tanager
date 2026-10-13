#include "elfload.h"

#include <elf.h>

#include <cstring>
#include <fstream>
#include <iterator>

#include "common.h"

namespace tg {

void elf_t::load(const std::string& path, mem_t& mem) {
  std::ifstream f(path, std::ios::binary);
  if (!f) fatal("cannot open ELF file %s", path.c_str());
  std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
  if (buf.size() < sizeof(Elf64_Ehdr)) fatal("%s: too short for an ELF file", path.c_str());

  Elf64_Ehdr eh;
  memcpy(&eh, buf.data(), sizeof eh);
  if (memcmp(eh.e_ident, ELFMAG, SELFMAG) != 0) fatal("%s: not an ELF file", path.c_str());
  if (eh.e_ident[EI_CLASS] != ELFCLASS64 || eh.e_ident[EI_DATA] != ELFDATA2LSB)
    fatal("%s: not a little-endian ELF64 file", path.c_str());
  if (eh.e_machine != EM_RISCV) fatal("%s: not a RISC-V ELF file", path.c_str());
  entry = eh.e_entry;

  auto in_file = [&](uint64_t off, uint64_t len) { return off <= buf.size() && len <= buf.size() - off; };

  for (unsigned i = 0; i < eh.e_phnum; i++) {
    uint64_t off = eh.e_phoff + (uint64_t)i * eh.e_phentsize;
    if (!in_file(off, sizeof(Elf64_Phdr))) fatal("%s: bad program header table", path.c_str());
    Elf64_Phdr ph;
    memcpy(&ph, buf.data() + off, sizeof ph);
    if (ph.p_type != PT_LOAD || ph.p_memsz == 0) continue;
    if (!in_file(ph.p_offset, ph.p_filesz)) fatal("%s: segment %u outside the file", path.c_str(), i);
    mem.write(ph.p_paddr, ph.p_filesz, buf.data() + ph.p_offset);
    if (ph.p_memsz > ph.p_filesz) {
      std::vector<uint8_t> zero(ph.p_memsz - ph.p_filesz, 0);
      mem.write(ph.p_paddr + ph.p_filesz, zero.size(), zero.data());
    }
    segments.push_back({ph.p_paddr, ph.p_filesz, ph.p_memsz});
  }

  // Symbols: the first SHT_SYMTAB section and its linked string table.
  for (unsigned i = 0; i < eh.e_shnum; i++) {
    uint64_t off = eh.e_shoff + (uint64_t)i * eh.e_shentsize;
    if (!in_file(off, sizeof(Elf64_Shdr))) break;
    Elf64_Shdr sh;
    memcpy(&sh, buf.data() + off, sizeof sh);
    if (sh.sh_type != SHT_SYMTAB || sh.sh_link >= eh.e_shnum) continue;
    Elf64_Shdr st;
    memcpy(&st, buf.data() + eh.e_shoff + (uint64_t)sh.sh_link * eh.e_shentsize, sizeof st);
    if (!in_file(sh.sh_offset, sh.sh_size) || !in_file(st.sh_offset, st.sh_size)) break;
    const char* strtab = reinterpret_cast<const char*>(buf.data() + st.sh_offset);
    for (uint64_t s = 0; s + sizeof(Elf64_Sym) <= sh.sh_size; s += sizeof(Elf64_Sym)) {
      Elf64_Sym sym;
      memcpy(&sym, buf.data() + sh.sh_offset + s, sizeof sym);
      if (sym.st_name == 0 || sym.st_name >= st.sh_size || sym.st_shndx == SHN_UNDEF) continue;
      std::string name(strtab + sym.st_name, strnlen(strtab + sym.st_name, st.sh_size - sym.st_name));
      if (name.empty() || name[0] == '$' || name[0] == '.') continue;  // mapping and local labels
      syms_.emplace(name, sym.st_value);
      unsigned type = ELF64_ST_TYPE(sym.st_info);
      if (type == STT_FUNC || type == STT_OBJECT || type == STT_NOTYPE) by_addr_.emplace(sym.st_value, name);
    }
    break;
  }
}

std::string elf_t::nearest(uint64_t addr) const {
  auto it = by_addr_.upper_bound(addr);
  if (it == by_addr_.begin()) return "";
  --it;
  if (addr - it->first > 0x100000) return "";
  return addr == it->first ? it->second : strfmt("%s+0x%llx", it->second.c_str(),
                                                 (unsigned long long)(addr - it->first));
}

}  // namespace tg
