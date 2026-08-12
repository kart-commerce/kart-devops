-- One shared Postgres instance for local dev; one database per service (all owned by the
-- default `postgres` superuser -- this is a throwaway dev container, not a security boundary).
-- kart-infra's kind/Helm path is where per-service DB users/isolation actually matter.
CREATE DATABASE kart_identity;
CREATE DATABASE kart_user;
CREATE DATABASE kart_product;
CREATE DATABASE kart_category;
CREATE DATABASE kart_inventory;
CREATE DATABASE kart_cart;
CREATE DATABASE kart_order;
CREATE DATABASE kart_payment;
CREATE DATABASE kart_offer;
CREATE DATABASE kart_wishlist;
CREATE DATABASE kart_notification;
CREATE DATABASE kart_admin;
