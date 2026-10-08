/**
 * Customer-facing copy that the synthetic dataset doesn't have: descriptions (EN/ES),
 * taste tags and photos. Prices, recipes and stock always come from data/barmade/*.json.
 */
import type { Lang } from "./i18n";

export type Localized = Record<Lang, string>;

export type Taste =
  | "cheesy"
  | "creamy"
  | "tomato"
  | "meaty"
  | "light"
  | "fresh"
  | "comfort"
  | "sweet"
  | "savory"
  | "spicy"
  | "coffee"
  | "bubbly";

export const TASTES: Taste[] = [
  "cheesy",
  "creamy",
  "tomato",
  "meaty",
  "light",
  "fresh",
  "comfort",
  "savory",
  "spicy",
  "sweet",
];

export interface DishCopy {
  image: string;
  name_es: string;
  description: Localized;
  tastes: Taste[];
}

/** Keyed by menu.json `key`. */
export const TRATTORIA_COPY: Record<string, DishCopy> = {
  pizza_margherita: {
    image: "/images/italian/margherita-pizza.jpg",
    name_es: "Pizza Margherita",
    description: {
      en: "Hand-stretched dough, bright tomato sauce, melted mozzarella and fresh basil.",
      es: "Masa estirada a mano, salsa de tomate, mozzarella fundida y albahaca fresca.",
    },
    tastes: ["cheesy", "tomato", "fresh"],
  },
  pizza_pepperoni: {
    image: "/images/italian/pepperoni-pizza.jpg",
    name_es: "Pizza de Pepperoni",
    description: {
      en: "Our classic pie loaded with crispy-edged pepperoni and mozzarella.",
      es: "Nuestra pizza clásica cargada de pepperoni crujiente y mozzarella.",
    },
    tastes: ["cheesy", "meaty", "tomato", "spicy"],
  },
  chicken_alfredo: {
    image: "/images/italian/chicken-alfredo.jpg",
    name_es: "Pasta Alfredo con Pollo",
    description: {
      en: "Spaghetti in a rich, creamy Alfredo sauce with grilled chicken, garlic and parmesan.",
      es: "Spaghetti en salsa Alfredo cremosa con pollo a la plancha, ajo y parmesano.",
    },
    tastes: ["creamy", "cheesy", "comfort", "savory"],
  },
  spaghetti_marinara: {
    image: "/images/italian/spaghetti-marinara.jpg",
    name_es: "Spaghetti Marinara",
    description: {
      en: "Spaghetti tossed in slow-simmered marinara with garlic, basil and olive oil.",
      es: "Spaghetti con salsa marinara cocida a fuego lento, ajo, albahaca y aceite de oliva.",
    },
    tastes: ["tomato", "light", "fresh"],
  },
  coca_cola: {
    image: "/images/italian/coca-cola.jpg",
    name_es: "Coca-Cola",
    description: { en: "Ice-cold 12 oz can.", es: "Lata de 12 oz bien fría." },
    tastes: ["bubbly", "sweet"],
  },
  lasagna: {
    image: "/images/italian/lasagna-bolognese.jpg",
    name_es: "Lasaña Boloñesa",
    description: {
      en: "Layers of pasta, beef ragù, ricotta and mozzarella, baked until golden.",
      es: "Capas de pasta, ragú de res, ricotta y mozzarella, horneada hasta dorar.",
    },
    tastes: ["meaty", "cheesy", "tomato", "comfort"],
  },
  carbonara: {
    image: "/images/italian/spaghetti-carbonara.jpg",
    name_es: "Spaghetti Carbonara",
    description: {
      en: "Roman-style: crispy pancetta, egg, parmesan and black pepper. No cream.",
      es: "Al estilo romano: panceta crujiente, huevo, parmesano y pimienta negra. Sin crema.",
    },
    tastes: ["savory", "meaty", "cheesy", "comfort"],
  },
  caesar_salad: {
    image: "/images/italian/caesar-salad.jpg",
    name_es: "Ensalada César",
    description: {
      en: "Crisp romaine, Caesar dressing, shaved parmesan and toasted breadcrumbs.",
      es: "Lechuga romana, aderezo César, parmesano rallado y pan tostado.",
    },
    tastes: ["light", "fresh", "savory"],
  },
  spaghetti_meatballs: {
    image: "/images/italian/spaghetti-meatballs.jpg",
    name_es: "Spaghetti con Albóndigas",
    description: {
      en: "House meatballs in tomato sauce over spaghetti, finished with parmesan and basil.",
      es: "Albóndigas de la casa en salsa de tomate sobre spaghetti, con parmesano y albahaca.",
    },
    tastes: ["meaty", "tomato", "comfort"],
  },
  meatball_parm: {
    image: "/images/italian/meatball-parm-hero.jpg",
    name_es: "Sándwich de Albóndigas a la Parmesana",
    description: {
      en: "Meatballs, tomato sauce and melted mozzarella on a toasted Italian hero.",
      es: "Albóndigas, salsa de tomate y mozzarella fundida en pan italiano tostado.",
    },
    tastes: ["meaty", "cheesy", "tomato", "comfort"],
  },
  penne_vodka: {
    image: "/images/italian/penne-alla-vodka.jpg",
    name_es: "Penne alla Vodka",
    description: {
      en: "Penne in a silky tomato-cream sauce with garlic and parmesan.",
      es: "Penne en una salsa sedosa de tomate y crema, con ajo y parmesano.",
    },
    tastes: ["creamy", "tomato", "comfort"],
  },
  chicken_parm: {
    image: "/images/italian/chicken-parmigiana.jpg",
    name_es: "Pollo a la Parmesana",
    description: {
      en: "Breaded chicken cutlet, tomato sauce and melted mozzarella, with a side of spaghetti.",
      es: "Milanesa de pollo empanizada, salsa de tomate y mozzarella, con spaghetti.",
    },
    tastes: ["meaty", "cheesy", "tomato", "comfort"],
  },
  pizza_funghi: {
    image: "/images/illustrations/funghi-pizza.svg",
    name_es: "Pizza de Hongos",
    description: {
      en: "Earthy roasted mushrooms, garlic, mozzarella and tomato.",
      es: "Champiñones asados, ajo, mozzarella y tomate.",
    },
    tastes: ["cheesy", "savory", "tomato"],
  },
  pizza_quattro_formaggi: {
    image: "/images/italian/quattro-formaggi-pizza.jpg",
    name_es: "Pizza Cuatro Quesos",
    description: {
      en: "Mozzarella, parmesan and ricotta on a white base with olive oil. For cheese lovers.",
      es: "Mozzarella, parmesano y ricotta sobre base blanca con aceite de oliva. Para amantes del queso.",
    },
    tastes: ["cheesy", "creamy", "comfort"],
  },
  garlic_bread: {
    image: "/images/italian/garlic-bread.jpg",
    name_es: "Pan de Ajo",
    description: {
      en: "Toasted Italian bread with garlic butter and parmesan.",
      es: "Pan italiano tostado con mantequilla de ajo y parmesano.",
    },
    tastes: ["savory", "comfort"],
  },
  tiramisu: {
    image: "/images/italian/tiramisu.jpg",
    name_es: "Tiramisú",
    description: {
      en: "Espresso-soaked ladyfingers layered with whipped mascarpone cream.",
      es: "Bizcochos de soletilla con espresso y crema de mascarpone.",
    },
    tastes: ["sweet", "creamy", "coffee"],
  },
  san_pellegrino: {
    image: "/images/italian/san-pellegrino.jpg",
    name_es: "San Pellegrino",
    description: { en: "Sparkling mineral water.", es: "Agua mineral con gas." },
    tastes: ["bubbly", "light"],
  },
};

export const CATEGORY_LABELS: Record<string, Localized> = {
  Pizza: { en: "Pizza", es: "Pizzas" },
  Pasta: { en: "Pasta", es: "Pastas" },
  Entree: { en: "Mains", es: "Platos fuertes" },
  Sandwich: { en: "Sandwiches", es: "Sándwiches" },
  Salad: { en: "Salads", es: "Ensaladas" },
  Appetizer: { en: "Starters", es: "Entradas" },
  Dessert: { en: "Desserts", es: "Postres" },
  Beverage: { en: "Drinks", es: "Bebidas" },
  Menu: { en: "Menu", es: "Menú" },
};

export const CATEGORY_ORDER = ["Pizza", "Pasta", "Entree", "Sandwich", "Salad", "Appetizer", "Dessert", "Beverage"];

export const MODIFIERS: Record<string, { label: Localized; price: number }> = {
  extra_cheese: { label: { en: "Extra cheese", es: "Extra queso" }, price: 2 },
  no_cheese: { label: { en: "No cheese", es: "Sin queso" }, price: 0 },
  add_chicken: { label: { en: "Add chicken", es: "Agregar pollo" }, price: 5 },
};

// ---------------------------------------------------------------------------
// Restaurants. Only the Trattoria takes orders; the others are browse-only
// showcases and are always closed in this demo (never flips on the clock).

export interface ShowcaseDish {
  id: string;
  name: Localized;
  description: Localized;
  price: number;
  image: string;
  tastes: Taste[];
}

export interface Restaurant {
  id: string;
  name: string;
  cuisine: Localized;
  neighborhood: string;
  cover: string;
  tagline: Localized;
  acceptsOrders: boolean;
  prepMinutes?: number;
  dishes?: ShowcaseDish[];
}

export const TRATTORIA_ID = "trattoria-little-italy";

const d = (
  id: string,
  en: string,
  es: string,
  price: number,
  image: string,
  tastes: Taste[],
  descEn: string,
  descEs: string,
): ShowcaseDish => ({ id, name: { en, es }, price, image, tastes, description: { en: descEn, es: descEs } });

export const RESTAURANTS: Restaurant[] = [
  {
    id: TRATTORIA_ID,
    name: "Trattoria Little Italy",
    cuisine: { en: "Italian", es: "Italiana" },
    neighborhood: "Little Italy",
    cover: "/images/covers/trattoria.jpg",
    tagline: {
      en: "Wood-fired pizza and fresh pasta, ready when you are.",
      es: "Pizza al horno y pasta fresca, lista cuando llegues.",
    },
    acceptsOrders: true,
    prepMinutes: 15,
  },
  {
    id: "la-ventanita-calle-8",
    name: "La Ventanita de Calle 8",
    cuisine: { en: "Cuban", es: "Cubana" },
    neighborhood: "Little Havana",
    cover: "/images/illustrations/ventanita.svg",
    tagline: { en: "Cafecito, croquetas and Cuban classics.", es: "Cafecito, croquetas y clásicos cubanos." },
    acceptsOrders: false,
    dishes: [
      d("cafecito", "Cafecito", "Cafecito", 1.75, "/images/illustrations/cafecito.svg", ["coffee", "sweet"],
        "Sweet, strong Cuban espresso.", "Espresso cubano dulce y fuerte."),
      d("croquetas", "Ham Croquetas", "Croquetas de Jamón", 1.5, "/images/illustrations/croquetas.svg", ["savory", "comfort"],
        "Crispy, creamy ham croquettes. Order a dozen.", "Croquetas de jamón crujientes y cremosas. Pide una docena."),
      d("cuban-sandwich", "Cuban Sandwich", "Sándwich Cubano", 11.5, "/images/illustrations/cuban-sandwich.svg", ["meaty", "savory", "cheesy"],
        "Roast pork, ham, Swiss, pickles and mustard, pressed on Cuban bread.",
        "Lechón, jamón, queso suizo, pepinillos y mostaza, prensado en pan cubano."),
      d("pan-con-lechon", "Pan con Lechón", "Pan con Lechón", 10.5, "/images/illustrations/pan-con-lechon.svg", ["meaty", "savory"],
        "Mojo-marinated roast pork and onions on toasted Cuban bread.",
        "Lechón asado en mojo con cebolla en pan cubano tostado."),
      d("ropa-vieja", "Ropa Vieja", "Ropa Vieja", 16.95, "/images/illustrations/ropa-vieja.svg", ["meaty", "tomato", "comfort"],
        "Shredded beef stewed with peppers, served with rice and sweet plantains.",
        "Carne deshebrada guisada con pimientos, con arroz y maduros."),
      d("pastelito-guayaba", "Guava Pastelito", "Pastelito de Guayaba", 1.95, "/images/illustrations/pastelito-guayaba.svg", ["sweet"],
        "Flaky puff pastry filled with guava.", "Hojaldre relleno de guayaba."),
    ],
  },
  {
    id: "brickell-sushi-co",
    name: "Brickell Sushi Co.",
    cuisine: { en: "Japanese", es: "Japonesa" },
    neighborhood: "Brickell",
    cover: "/images/illustrations/sushi.svg",
    tagline: { en: "Fresh rolls for the downtown lunch rush.", es: "Rolls frescos para el almuerzo en downtown." },
    acceptsOrders: false,
    dishes: [
      d("salmon-nigiri", "Salmon Nigiri", "Nigiri de Salmón", 7.5, "/images/illustrations/salmon-nigiri.svg", ["fresh", "light"],
        "Two pieces of fresh salmon over seasoned rice.", "Dos piezas de salmón fresco sobre arroz sazonado."),
      d("spicy-tuna-roll", "Spicy Tuna Roll", "Roll de Atún Picante", 9.5, "/images/illustrations/spicy-tuna-roll.svg", ["spicy", "fresh"],
        "Tuna, spicy mayo and cucumber.", "Atún, mayonesa picante y pepino."),
      d("dragon-roll", "Dragon Roll", "Dragon Roll", 14, "/images/illustrations/dragon-roll.svg", ["savory", "creamy"],
        "Shrimp tempura topped with avocado and eel sauce.", "Tempura de camarón con aguacate y salsa de anguila."),
      d("miso-soup", "Miso Soup", "Sopa Miso", 4, "/images/illustrations/miso-soup.svg", ["light", "savory"],
        "Tofu, wakame and scallions.", "Tofu, wakame y cebollín."),
      d("edamame", "Edamame", "Edamame", 5, "/images/illustrations/edamame.svg", ["light", "fresh"],
        "Steamed with sea salt.", "Al vapor con sal de mar."),
    ],
  },
  {
    id: "wynwood-greens",
    name: "Wynwood Greens",
    cuisine: { en: "Healthy bowls", es: "Bowls saludables" },
    neighborhood: "Wynwood",
    cover: "/images/illustrations/greens.svg",
    tagline: { en: "Bowls, salads and smoothies that keep you going.", es: "Bowls, ensaladas y batidos con energía." },
    acceptsOrders: false,
    dishes: [
      d("acai-bowl", "Açaí Bowl", "Bowl de Açaí", 12, "/images/illustrations/acai-bowl.svg", ["sweet", "fresh", "light"],
        "Açaí, banana, granola, berries and honey.", "Açaí, plátano, granola, frutos rojos y miel."),
      d("quinoa-power-bowl", "Quinoa Power Bowl", "Bowl de Quinoa", 13.5, "/images/illustrations/quinoa-power-bowl.svg", ["fresh", "light"],
        "Quinoa, chickpeas, avocado, greens and lemon tahini.", "Quinoa, garbanzos, aguacate, hojas verdes y tahini de limón."),
      d("avocado-toast", "Avocado Toast", "Tostada de Aguacate", 10, "/images/illustrations/avocado-toast.svg", ["fresh", "savory"],
        "Smashed avocado, chili flakes and lime on sourdough.", "Aguacate, chile en hojuelas y limón sobre pan de masa madre."),
      d("mango-kale-salad", "Mango Kale Salad", "Ensalada de Kale y Mango", 11.5, "/images/illustrations/mango-kale-salad.svg", ["fresh", "light", "sweet"],
        "Kale, mango, toasted pepitas and citrus dressing.", "Kale, mango, pepitas tostadas y aderezo cítrico."),
      d("green-smoothie", "Green Smoothie", "Batido Verde", 8, "/images/illustrations/green-smoothie.svg", ["fresh", "light"],
        "Spinach, pineapple, banana and ginger.", "Espinaca, piña, plátano y jengibre."),
    ],
  },
];

export function restaurantById(id: string) {
  return RESTAURANTS.find((r) => r.id === id);
}
