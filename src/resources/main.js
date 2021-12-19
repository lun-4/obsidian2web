window.onload = function () {
  const toggler = document.getElementsByClassName("caret");
  for (const element of toggler) {
    element.addEventListener("click", function () {
      this.parentElement.querySelector(".nested").classList.toggle("active");
      this.classList.toggle("caret-down");
    });
  }
};
