const treeMap = {};

function registerTreeToggles() {
  const toggler = document.getElementsByClassName("caret");
  for (const element of toggler) {
    treeMap[element.innerText] = element;
    element.addEventListener("click", function () {
      this.parentElement.querySelector(".nested").classList.toggle("active");
      this.classList.toggle("caret-down");
    });
  }
}

// Based on document.location, open the necessary tree buttons
function openTreeFromPath() {
  const path = decodeURIComponent(window.location.pathname);
  for (let raw_component of path.split("/")) {
    if (!raw_component) continue;
    if (raw_component.endsWith(".html")) {
      raw_component = raw_component.slice(0, -5);
    }
    const component = raw_component;
    const element = treeMap[component];
    if (!element) continue;
    element.parentElement.querySelector(".nested").classList.toggle("active");
    element.classList.toggle("caret-down");
  }
}

window.onload = function () {
  registerTreeToggles();
  openTreeFromPath();
};
