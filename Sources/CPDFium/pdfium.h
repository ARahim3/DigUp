// The PDFium headers the engine uses. On Windows fpdfview.h includes windows.h for one declaration, FPDF_RenderPage
// (GDI drawing, never used here), whose HDC type Swift's Windows SDK module doesn't make visible to this one: the
// include is skipped (its own __WINDOWS__ guard) and HDC stands for an opaque pointer while the headers are read.
#ifdef _WIN32
#define __WINDOWS__
#define HDC void *
#endif
#include "../../Vendor/pdfium/include/fpdfview.h"
#include "../../Vendor/pdfium/include/fpdf_text.h"
#include "../../Vendor/pdfium/include/fpdf_doc.h"
#ifdef _WIN32
#undef HDC
#undef __WINDOWS__
#endif
