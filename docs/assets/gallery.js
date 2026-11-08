const gallery = document.querySelector("#screenshots");
const viewer = document.querySelector("#screenshot-viewer");

if (typeof viewer.showModal === "function") {
  const slides = [...gallery.querySelectorAll("figure a, .screenshot-overview a")];
  const stage = viewer.querySelector(".viewer-stage");
  const image = stage.querySelector("img");
  const name = viewer.querySelector(".viewer-name");
  const count = viewer.querySelector(".viewer-count");
  let current = 0;
  let opener;
  let swipeStart;

  function showSlide(index) {
    current = (index + slides.length) % slides.length;
    const slide = slides[current];
    image.alt = slide.querySelector("img").alt;
    image.src = slide.href;
    name.textContent = image.alt;
    count.textContent = `${current + 1} / ${slides.length}`;
  }

  slides.forEach((slide, index) => {
    slide.setAttribute("aria-haspopup", "dialog");
    slide.addEventListener("click", event => {
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      opener = slide;
      showSlide(index);
      viewer.showModal();
    });
  });

  for (const button of viewer.querySelectorAll("[data-step]")) {
    button.addEventListener("click", () => showSlide(current + Number(button.dataset.step)));
  }

  viewer.addEventListener("keydown", event => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      showSlide(current + (event.key === "ArrowLeft" ? -1 : 1));
    }
  });

  stage.addEventListener("pointerdown", event => {
    if (event.pointerType === "touch" && event.isPrimary) {
      swipeStart = { x: event.clientX, y: event.clientY, id: event.pointerId };
    }
  });
  stage.addEventListener("pointerup", event => {
    if (swipeStart?.id !== event.pointerId) return;
    const dx = event.clientX - swipeStart.x;
    const dy = event.clientY - swipeStart.y;
    swipeStart = undefined;
    if (Math.abs(dx) >= 45 && Math.abs(dx) > Math.abs(dy) * 1.5) {
      showSlide(current + (dx < 0 ? 1 : -1));
    }
  });
  stage.addEventListener("pointercancel", event => {
    if (swipeStart?.id === event.pointerId) swipeStart = undefined;
  });

  viewer.addEventListener("click", event => {
    if (event.target === viewer) viewer.close();
  });
  viewer.addEventListener("close", () => {
    swipeStart = undefined;
    opener?.focus({ preventScroll: true });
  });
}
