# Copyright 2014 Patrick Dawson <pat@dw.is>
#
# This software is provided 'as-is', without any express or implied
# warranty.  In no event will the authors be held liable for any damages
# arising from the use of this software.
#
# Permission is granted to anyone to use this software for any purpose,
# including commercial applications, and to alter it and redistribute it
# freely, subject to the following restrictions:
#
# 1. The origin of this software must not be misrepresented; you must not
#    claim that you wrote the original software. If you use this software
#    in a product, an acknowledgment in the product documentation would be
#    appreciated but is not required.
# 2. Altered source versions must be plainly marked as such, and must not be
#    misrepresented as being the original software.
# 3. This notice may not be removed or altered from any source distribution.

from sdl2 cimport *
from sdl2_image cimport *
from libc.string cimport memcpy, memset
from libc.stdlib cimport malloc, free
from pygame_sdl2.display cimport *
from pygame_sdl2.surface cimport *
from pygame_sdl2.rwobject cimport to_rwops
from pygame_sdl2.rect cimport to_sdl_rect

from pygame_sdl2.rect import Rect
from pygame_sdl2.error import error
from pygame_sdl2.color import Color
import json
import warnings

BLENDMODE_NONE = SDL_BLENDMODE_NONE
BLENDMODE_BLEND = SDL_BLENDMODE_BLEND
BLENDMODE_ADD = SDL_BLENDMODE_ADD
BLENDMODE_MOD = SDL_BLENDMODE_MOD

SCALEMODE_NEAREST = SDL_ScaleModeNearest
SCALEMODE_LINEAR = SDL_ScaleModeLinear
SCALEMODE_BEST = SDL_ScaleModeBest

TEXTUREACCESS_STATIC = SDL_TEXTUREACCESS_STATIC
TEXTUREACCESS_STREAMING = SDL_TEXTUREACCESS_STREAMING
TEXTUREACCESS_TARGET = SDL_TEXTUREACCESS_TARGET

cdef bint DEBUG_DRAW_BBOX = True

cdef rinfo_to_dict(SDL_RendererInfo *rinfo):
    # Ignore texture_formats for now.
    return {
            "name" : rinfo.name,
            "software" : rinfo.flags & SDL_RENDERER_SOFTWARE != 0,
            "accelerated" : rinfo.flags & SDL_RENDERER_ACCELERATED != 0,
            "vsync" : rinfo.flags & SDL_RENDERER_PRESENTVSYNC != 0,
            "rtt" : rinfo.flags & SDL_RENDERER_TARGETTEXTURE != 0,
            "max_texture_width" : rinfo.max_texture_width,
            "max_texture_height" : rinfo.max_texture_height,
    }

def get_drivers():
    cdef SDL_RendererInfo rinfo
    cdef int num_drivers
    rv = []

    num_drivers = SDL_GetNumRenderDrivers()
    for n in range(num_drivers):
        if SDL_GetRenderDriverInfo(n, &rinfo) != 0:
            raise error()

        rv.append(rinfo_to_dict(&rinfo))

    return rv


cdef class Renderer:
    cdef SDL_Renderer *renderer
    cdef dict _info

    def __cinit__(self):
        self.renderer = NULL

    def __dealloc__(self):
        if self.renderer:
            SDL_DestroyRenderer(self.renderer)

    def __init__(self, Window window=None, vsync=False, driver=-1):
        if window is None:
            window = main_window

        cdef uint32_t flags = SDL_RENDERER_ACCELERATED
        if vsync:
            flags |= SDL_RENDERER_PRESENTVSYNC

        self.renderer = SDL_CreateRenderer(window.window, driver, flags)
        if self.renderer == NULL:
            self.renderer = SDL_GetRenderer(window.window)
            if self.renderer == NULL:
                raise error()

        cdef SDL_RendererInfo rinfo
        if SDL_GetRendererInfo(self.renderer, &rinfo) != 0:
            raise error()

        self._info = rinfo_to_dict(&rinfo)

        if not self.info()["accelerated"]:
            warnings.warn("Renderer is not accelerated.")

    def load_texture(self, fi):
        cdef SDL_Texture *tex
        cdef Texture t = Texture()

        if isinstance(fi, Surface):
            tex = SDL_CreateTextureFromSurface(self.renderer, (<Surface>fi).surface)
        else:
            tex = IMG_LoadTexture_RW(self.renderer, to_rwops(fi), 1)

        if tex == NULL:
            raise error()

        t.set(self.renderer, tex)
        return TextureNode(t)

    def load_atlas(self, filename):
        """ Loads a file in the popular JSON (Hash) format exported by
            TexturePacker and other software. """

        return TextureAtlas(self, filename)

    def render_present(self):
        with nogil:
            SDL_RenderPresent(self.renderer)

    def info(self):
        return self._info

    cdef set_drawcolor(self, col):
        if not isinstance(col, Color):
            col = Color(col)
        SDL_SetRenderDrawColor(self.renderer, col.r, col.g, col.b, col.a)

    def clear(self, color):
        self.set_drawcolor(color)
        SDL_RenderClear(self.renderer)

    def draw_line(self, color not None, x1, y1, x2, y2):
        self.set_drawcolor(color)
        if SDL_RenderDrawLine(self.renderer, x1, y1, x2, y2) != 0:
            raise error()

    def draw_point(self, color not None, x, y):
        self.set_drawcolor(color)
        SDL_RenderDrawPoint(self.renderer, x, y)

    def draw_rect(self, color not None, rect):
        cdef SDL_Rect r
        to_sdl_rect(rect, &r)
        self.set_drawcolor(color)
        SDL_RenderDrawRect(self.renderer, &r)

    def fill_rect(self, color not None, rect):
        cdef SDL_Rect r
        to_sdl_rect(rect, &r)
        self.set_drawcolor(color)
        SDL_RenderFillRect(self.renderer, &r)

    def set_viewport(self, rect=None):
        cdef SDL_Rect vprect
        if rect is None:
            SDL_RenderSetViewport(self.renderer, NULL)
        else:
            to_sdl_rect(rect, &vprect)
            SDL_RenderSetViewport(self.renderer, &vprect)

    def create_texture(self, size):
        if SDL_RenderTargetSupported(self.renderer) != SDL_TRUE:
            raise error()

    def create_target_texture(self, int w, int h):
        """Create an RGBA texture that can be used as a render target."""
        if SDL_RenderTargetSupported(self.renderer) != SDL_TRUE:
            raise error("Render targets not supported")

        cdef SDL_Texture *tex = SDL_CreateTexture(
            self.renderer, SDL_PIXELFORMAT_ARGB8888,
            SDL_TEXTUREACCESS_TARGET, w, h)
        if tex == NULL:
            raise error()

        cdef GPUTexture gt = GPUTexture.__new__(GPUTexture)
        gt.texture = tex
        gt.renderer = self.renderer
        gt.w = w
        gt.h = h
        gt.owned = True
        return gt

    def create_texture_from_surface(self, Surface surf not None):
        """Upload a pygame Surface to a GPU texture."""
        # Disable RLE encoding before upload. SDL_ConvertSurface may copy
        # the RLE flag from the source, causing the pixel buffer to be
        # RLE-encoded. SDL_UpdateTexture reads raw bytes and doesn't handle
        # RLE, resulting in corrupted texture data on D3D12.
        SDL_SetSurfaceRLE(surf.surface, 0)

        cdef SDL_Texture *tex = SDL_CreateTextureFromSurface(
            self.renderer, surf.surface)
        if tex == NULL:
            raise error()

        cdef int w, h
        cdef Uint32 fmt
        cdef int access
        SDL_QueryTexture(tex, &fmt, &access, &w, &h)

        cdef GPUTexture gt = GPUTexture.__new__(GPUTexture)
        gt.texture = tex
        gt.renderer = self.renderer
        gt.w = w
        gt.h = h
        gt.owned = True
        return gt

    def set_render_target(self, GPUTexture target=None):
        """Set the render target. Pass None to target the default (screen)."""
        cdef SDL_Texture *tex = NULL
        if target is not None:
            tex = target.texture
        if SDL_SetRenderTarget(self.renderer, tex) != 0:
            raise error()

    def get_renderer_output_size(self):
        """Return (w, h) of the renderer output."""
        cdef int w, h
        if SDL_GetRendererOutputSize(self.renderer, &w, &h) != 0:
            raise error()
        return (w, h)

    def set_logical_size(self, int w, int h):
        """Set the logical rendering size for resolution independence."""
        if SDL_RenderSetLogicalSize(self.renderer, w, h) != 0:
            raise error()

    def get_logical_size(self):
        """Return the current logical size as (w, h)."""
        cdef int w, h
        SDL_RenderGetLogicalSize(self.renderer, &w, &h)
        return (w, h)

    def set_draw_blend_mode(self, int mode):
        SDL_SetRenderDrawBlendMode(self.renderer, <SDL_BlendMode>mode)

    def set_clip_rect(self, rect=None):
        """Set the clip rectangle. Pass None to disable clipping."""
        cdef SDL_Rect r
        if rect is None:
            SDL_RenderSetClipRect(self.renderer, NULL)
        else:
            to_sdl_rect(rect, &r)
            SDL_RenderSetClipRect(self.renderer, &r)

    def render_copy_f(self, GPUTexture tex not None, src_rect=None, dst_rect=None):
        """Copy a texture to the renderer with float precision dest."""
        cdef SDL_Rect sr
        cdef SDL_Rect *srp = NULL
        cdef SDL_FRect dr
        cdef SDL_FRect *drp = NULL

        if src_rect is not None:
            to_sdl_rect(src_rect, &sr)
            srp = &sr
        if dst_rect is not None:
            dr.x = <float>dst_rect[0]
            dr.y = <float>dst_rect[1]
            dr.w = <float>dst_rect[2]
            dr.h = <float>dst_rect[3]
            drp = &dr

        SDL_RenderCopyF(self.renderer, tex.texture, srp, drp)

    def render_copy_ex_f(self, GPUTexture tex not None, src_rect=None,
                         dst_rect=None, double angle=0.0, center=None, int flip=0):
        """Copy a texture with rotation/flip and float precision dest."""
        cdef SDL_Rect sr
        cdef SDL_Rect *srp = NULL
        cdef SDL_FRect dr
        cdef SDL_FRect *drp = NULL
        cdef SDL_FPoint cp
        cdef SDL_FPoint *cpp = NULL

        if src_rect is not None:
            to_sdl_rect(src_rect, &sr)
            srp = &sr
        if dst_rect is not None:
            dr.x = <float>dst_rect[0]
            dr.y = <float>dst_rect[1]
            dr.w = <float>dst_rect[2]
            dr.h = <float>dst_rect[3]
            drp = &dr
        if center is not None:
            cp.x = <float>center[0]
            cp.y = <float>center[1]
            cpp = &cp

        SDL_RenderCopyExF(self.renderer, tex.texture, srp, drp,
                          angle, cpp, <SDL_RendererFlip>flip)

    def render_geometry(self, GPUTexture tex, vertices, indices=None):
        """Render textured geometry (triangles).

        vertices: list of (pos_x, pos_y, color_r, color_g, color_b, color_a, tex_u, tex_v)
        indices: list of int indices, or None
        """
        cdef int num_verts = len(vertices)
        cdef SDL_Vertex *verts = <SDL_Vertex *>malloc(num_verts * sizeof(SDL_Vertex))
        if verts == NULL:
            raise MemoryError()

        cdef int i
        for i in range(num_verts):
            v = vertices[i]
            verts[i].position.x = <float>v[0]
            verts[i].position.y = <float>v[1]
            verts[i].color.r = <Uint8>v[2]
            verts[i].color.g = <Uint8>v[3]
            verts[i].color.b = <Uint8>v[4]
            verts[i].color.a = <Uint8>v[5]
            verts[i].tex_coord.x = <float>v[6]
            verts[i].tex_coord.y = <float>v[7]

        cdef SDL_Texture *sdl_tex = NULL
        if tex is not None:
            sdl_tex = tex.texture

        cdef int *idx = NULL
        cdef int num_idx = 0
        if indices is not None:
            num_idx = len(indices)
            idx = <int *>malloc(num_idx * sizeof(int))
            if idx == NULL:
                free(verts)
                raise MemoryError()
            for i in range(num_idx):
                idx[i] = <int>indices[i]

        cdef int result = SDL_RenderGeometry(
            self.renderer, sdl_tex, verts, num_verts, idx, num_idx)

        free(verts)
        if idx != NULL:
            free(idx)

        if result != 0:
            raise error()

    def render_read_pixels(self, rect=None):
        """Read pixels from the current render target into a new Surface."""
        cdef SDL_Rect r
        cdef SDL_Rect *rp = NULL
        cdef int w, h

        if rect is not None:
            to_sdl_rect(rect, &r)
            rp = &r
            w = r.w
            h = r.h
        else:
            SDL_GetRendererOutputSize(self.renderer, &w, &h)

        import pygame_sdl2
        surf = pygame_sdl2.Surface((w, h), 0, 32)
        cdef Surface pysurf = <Surface>surf

        if SDL_RenderReadPixels(self.renderer, rp,
                                SDL_PIXELFORMAT_ARGB8888,
                                pysurf.surface.pixels,
                                pysurf.surface.pitch) != 0:
            raise error()

        return surf

    def render_target_supported(self):
        return SDL_RenderTargetSupported(self.renderer) == SDL_TRUE


cdef class GPUTexture:
    """A GPU texture handle for use with the SDL_Renderer-based renderer."""

    cdef SDL_Texture *texture
    cdef SDL_Renderer *renderer
    cdef public int w, h
    cdef bint owned

    def __cinit__(self):
        self.texture = NULL
        self.renderer = NULL
        self.w = 0
        self.h = 0
        self.owned = False

    def __dealloc__(self):
        if self.owned and self.texture != NULL:
            SDL_DestroyTexture(self.texture)
            self.texture = NULL

    def destroy(self):
        """Explicitly destroy the texture."""
        if self.texture != NULL:
            SDL_DestroyTexture(self.texture)
            self.texture = NULL
            self.owned = False

    @property
    def valid(self):
        return self.texture != NULL

    @property
    def size(self):
        return (self.w, self.h)

    def set_alpha_mod(self, int alpha):
        if self.texture != NULL:
            SDL_SetTextureAlphaMod(self.texture, <Uint8>alpha)

    def set_color_mod(self, int r, int g, int b):
        if self.texture != NULL:
            SDL_SetTextureColorMod(self.texture, <Uint8>r, <Uint8>g, <Uint8>b)

    def set_blend_mode(self, int mode):
        if self.texture != NULL:
            SDL_SetTextureBlendMode(self.texture, <SDL_BlendMode>mode)

    def set_scale_mode(self, int mode):
        if self.texture != NULL:
            SDL_SetTextureScaleMode(self.texture, <SDL_ScaleMode>mode)


cdef class Texture:
    """ Mostly for internal use. Users should only see this for RTT. """

    cdef SDL_Renderer *renderer
    cdef SDL_Texture *texture
    cdef public int w, h

    def __cinit__(self):
        self.texture = NULL

    def __dealloc__(self):
        if self.texture:
            SDL_DestroyTexture(self.texture)

    cdef set(self, SDL_Renderer *ren, SDL_Texture *tex):
        cdef Uint32 format
        cdef int access, w, h

        self.renderer = ren
        self.texture = tex

        if SDL_QueryTexture(self.texture, &format, &access, &w, &h) != 0:
            raise error()

        self.w = w
        self.h = h


cdef class TextureNode:
    """ A specified area of a texture. """

    cdef Texture texture

    # The absolute rect within the texture.
    cdef SDL_Rect source_rect

    # The relative rect within the original tile.
    cdef SDL_Rect trimmed_rect

    # The dimensions of the original tile.
    cdef int source_w
    cdef int source_h

    def __init__(self, tex):
        if isinstance(tex, Texture):
            self.texture = tex
            to_sdl_rect((0,0,tex.w,tex.h), &self.source_rect)
            to_sdl_rect((0,0,tex.w,tex.h), &self.trimmed_rect)
            self.source_w = tex.w
            self.source_h = tex.h

        elif isinstance(tex, TextureNode):
            self.texture = (<TextureNode>tex).texture

        else:
            raise ValueError()

    def render(self, dest=None):
        cdef SDL_Rect dest_rect

        if dest is None:
            with nogil:
                SDL_RenderCopy(self.texture.renderer, self.texture.texture, NULL, NULL)

        else:
            to_sdl_rect(dest, &dest_rect)
            with nogil:
                if dest_rect.w == 0 or dest_rect.h == 0:
                    dest_rect.w = self.trimmed_rect.w
                    dest_rect.h = self.trimmed_rect.h
                SDL_RenderCopy(self.texture.renderer, self.texture.texture, NULL, &dest_rect)


cdef class TextureAtlas:
    cdef object frames

    def __init__(self, Renderer ren, fi):
        jdata = json.load(open(fi, "r"))
        image = jdata["meta"]["image"]

        cdef TextureNode tn = ren.load_texture(image)

        self.frames = {}

        cdef TextureNode itex
        for itm in jdata["frames"].items():
            iname, idict = itm
            itex = TextureNode(tn)
            f = idict["frame"]
            to_sdl_rect((f['x'], f['y'], f['w'], f['h']), &itex.source_rect, "frame")
            f = idict["spriteSourceSize"]
            to_sdl_rect((f['x'], f['y'], f['w'], f['h']), &itex.trimmed_rect, "spriteSourceSize")
            if idict["rotated"]:
                raise error("Rotation not supported yet.")
            itex.source_w = idict["sourceSize"]["w"]
            itex.source_h = idict["sourceSize"]["h"]

            self.frames[iname] = itex

    def __getitem__(self, key):
        return self.frames[key]

    def keys(self):
        return self.frames.keys()


cdef class Sprite:
    """ One or more TextureNodes, with possible transforms applied. """

    cdef list nodes
    cdef SDL_Rect _pos
    cdef SDL_Rect bounding_box

    cdef double _rotation
    cdef int _flip
    cdef SDL_Color _color
    cdef double _scalex
    cdef double _scaley

    def __init__(self, nodes):
        self._color.r = 255
        self._color.g = 255
        self._color.b = 255
        self._color.a = 255
        self._scalex = 1.0
        self._scaley = 1.0
        self._flip = SDL_FLIP_NONE

        memset(&self._pos, 0, sizeof(SDL_Rect))
        memset(&self.bounding_box, 0, sizeof(SDL_Rect))

        if isinstance(nodes, TextureNode):
            nodes = [nodes]

        self.nodes = []
        # TODO: Check that they're all from the same texture.
        for node in nodes:
            if not isinstance(node, TextureNode):
                raise ValueError("Invalid argument: %s" % node)
            SDL_UnionRect(&self.bounding_box, &(<TextureNode>node).trimmed_rect,
                &self.bounding_box)
            self.nodes.append(node)

    cdef void adjust_rect(Sprite self, const SDL_Rect *dest, const SDL_Rect *rin, SDL_Rect *rout) nogil:
        rout.x = dest.x + <int>(self._scalex * rin.x)
        rout.y = dest.y + <int>(self._scaley * rin.y)
        rout.w = <int>(self._scalex * rin.w)
        rout.h = <int>(self._scaley * rin.h)

    def render(self, dest=None):
        cdef Texture tex = (<TextureNode>self.nodes[0]).texture
        cdef SDL_Rect dest_rect
        cdef SDL_Rect real_dest
        cdef SDL_Point pivot

        if dest is None:
            memcpy(&dest_rect, &self._pos, sizeof(SDL_Rect))
        else:
            to_sdl_rect(dest, &dest_rect)

        with nogil:
            SDL_SetTextureColorMod(tex.texture, self._color.r, self._color.g, self._color.b)
            SDL_SetTextureAlphaMod(tex.texture, self._color.a)

            if DEBUG_DRAW_BBOX:
                # TODO: Adjust for rotation.
                self.adjust_rect(&dest_rect, &self.bounding_box, &real_dest)

                SDL_SetRenderDrawColor(tex.renderer, 0x00, 0x00, 0x00, 0x00)

        cdef TextureNode tn
        for x in self.nodes:
            tn = <TextureNode> x

            with nogil:
                pivot.x = <int>(self._scalex * (tn.source_w / 2 - tn.trimmed_rect.x))
                pivot.y = <int>(self._scaley * (tn.source_h / 2 - tn.trimmed_rect.y))

                self.adjust_rect(&dest_rect, &tn.trimmed_rect, &real_dest)

                SDL_RenderCopyEx(tex.renderer, tex.texture, &tn.source_rect,
                    &real_dest, self._rotation, &pivot,
                    <SDL_RendererFlip>self._flip)

    def collides(self, Sprite other not None):
        cdef SDL_Rect r1, r2

        self.adjust_rect(&self._pos, &self.bounding_box, &r1)
        other.adjust_rect(&other._pos, &other.bounding_box, &r2)

        return SDL_HasIntersection(&r1, &r2) == SDL_TRUE

    property pos:
        def __get__(self):
            return self._pos.x, self._pos.y

        def __set__(self, val):
            self._pos.x = val[0]
            self._pos.y = val[1]

    property color:
        def __set__(self, val):
            if not isinstance(val, Color):
                val = Color(val)

            self._color.r = val.r
            self._color.g = val.g
            self._color.b = val.b
            self._color.a = val.a

    property alpha:
        def __get__(self):
            return self._color.a

        def __set__(self, val):
            self._color.a = val

    property rotation:
        def __get__(self):
            return self._rotation

        def __set__(self, val):
            self._rotation = val

    property scale:
        def __get__(self):
            if self._scalex == self._scaley:
                return self._scalex
            else:
                return self._scalex, self._scaley

        def __set__(self, arg):
            if type(arg) == tuple:
                x, y = arg
            else:
                x = y = arg

            self._scalex = x
            self._scaley = y

    property hflip:
        def __get__(self):
            return self._flip & SDL_FLIP_HORIZONTAL

        def __set__(self, val):
            if val:
                self._flip |= SDL_FLIP_HORIZONTAL
            else:
                self._flip &= ~SDL_FLIP_HORIZONTAL

    property vflip:
        def __get__(self):
            return self._flip & SDL_FLIP_VERTICAL

        def __set__(self, val):
            if val:
                self._flip |= SDL_FLIP_VERTICAL
            else:
                self._flip &= ~SDL_FLIP_VERTICAL


cdef class Container:
    """ Multiple sprites, positioned relative to the container. """

    cdef SDL_Rect _rect
    cdef list sprites

    def __init__(self, rect):
        """ Parameter may be a position (no clipping) or a rect (clipped). """

        self.sprites = []
        to_sdl_rect(rect, &self._rect)
        if len(rect) == 2:
            self._rect.w = self._rect.h = 0

    def add(self, Sprite sprite not None):
        self.sprites.append(sprite)

    def render(self, dest=None):
        # TODO: Something other than this to get the SDL_Renderer.
        cdef SDL_Renderer *ren = (<TextureNode>(<Sprite>self.sprites[0]).nodes[0]).texture.renderer

        if self._rect.w != 0 and self._rect.h != 0:
            SDL_RenderSetClipRect(ren, &self._rect)

        for s in self.sprites:
            s.render((s.pos[0] + self._rect.x, s.pos[1] + self._rect.y))

        # TODO: Save and restore previous clip rect instead?
        SDL_RenderSetClipRect(ren, NULL)

    property pos:
        def __get__(self):
            return self._rect.x, self._rect.y

        def __set__(self, val):
            self._rect.x = val[0]
            self._rect.y = val[1]

    property rect:
        def __get__(self):
            return Rect(self._rect.x, self._rect.y, self._rect.w, self._rect.h)

        def __set__(self, val):
            to_sdl_rect(val, &self._rect)

