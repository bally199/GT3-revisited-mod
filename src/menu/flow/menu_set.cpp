#include "menu/flow/menu_set.h"

#include "menu/menu_renderer.h"

#include <SDL3/SDL_timer.h>

#include "base/log.h"
#include "vfs/vfs.h"

namespace gt3r::menu::flow {

FileReader vfs_reader(const Vfs& vfs) {
    return [&vfs](const std::string& path) { return vfs.read(path); };
}

MenuPatches& menu_patches() {
    static MenuPatches p;
    return p;
}

MenuSet::MenuSet(FileReader reader, std::string name, std::string lang)
    : reader_(std::move(reader)), name_(std::move(name)), lang_(std::move(lang)) {
    std::string path = "menu/" + name_ + ".mbl";
    auto data = reader_(path);
    if (!data) throw FormatError("cannot read " + path);
    mbl_ = MblFile::parse(*data);
    if (menu_patches().flow) menu_patches().flow(name_, reader_, mbl_);
}

std::string MenuSet::pmb_path(int n) const { return "menu/" + lang_ + "/" + name_ + std::to_string(n) + ".pmb"; }

const MenuScene* MenuSet::scene(int n) const {
    auto it = scenes_.find(n);
    if (it != scenes_.end()) return it->second.get();
    std::unique_ptr<MenuScene> s;
    std::string path = pmb_path(n);
    const u64 t0 = SDL_GetTicksNS();
    try {
        if (auto data = reader_(path)) s = std::make_unique<MenuScene>(MenuScene::load(*data, path));
        if (s) MenuRenderer::warm(*s); // (its art's replacements get a head start on the screen change)
        if (s) LOG_INFO("menu: %s loaded in %.0f ms (%zu images)", path.c_str(), double(SDL_GetTicksNS() - t0) / 1e6,
                        s->images().size());
        else LOG_WARN("menu: cannot load [%s]", path.c_str());
        if (s && menu_patches().layout) menu_patches().layout(name_, n, reader_, *s);
    } catch (const std::exception& e) {
        LOG_WARN("menu: %s: %s", path.c_str(), e.what());
    }
    return (scenes_[n] = std::move(s)).get();
}

MenuSet::PageRef MenuSet::page(std::string_view name) const {
    PageRef r;
    int fp = mbl_.find_page(name);
    if (fp >= 0) r.flow = &mbl_.pages[size_t(fp)];
    int n = r.flow ? pmb_number(*r.flow) : 1;
    if (n <= 0) n = 1;
    r.scene = scene(n);
    if (r.scene) r.page = r.scene->file().find_page(name);
    return r;
}

} // namespace gt3r::menu::flow
